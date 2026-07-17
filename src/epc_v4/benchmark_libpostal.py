from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.metadata
import importlib.util
import json
import platform
import re
import shutil
import subprocess
import threading
import time
from collections import defaultdict
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import duckdb
import pandas as pd
import psutil

from epc_v4.stable_keys import stable_sha256

LIBPOSTAL_COMMIT = "25099c506612b34b23b1bfe286ca6321fcf06f35"
PYPPOSTAL_COMMIT = "d6666a4f6a2ae0e7b83e037a35412f0f6b45c318"
BENCHMARK_CONTRACT_VERSION = "libpostal_epc_ppd_v5"
DEFAULT_SAMPLE_SEED = "epc-v4-libpostal-default-v1"

NON_ALNUM = re.compile(r"[^A-Z0-9]+")
NUMBER_TOKEN = re.compile(r"(?<![A-Z0-9])([0-9]+[A-Z]?)(?![A-Z0-9])")
NUMBER_DESIGNATOR = re.compile(
    r"(?<![A-Z0-9])([0-9]+[A-Z]?(?:[ ]*-[ ]*[0-9]+[A-Z]?)?)(?![A-Z0-9])"
)
UNIT_PREFIX = re.compile(r"^(FLAT|APARTMENT|APT|UNIT|ROOM|MAISONETTE)[ ]*")

SYNTHETIC_FIXTURES = (
    {
        "fixture_name": "FLAT_THEN_BUILDING",
        "parser_input": "Flat 5, 11 High Street, London, SW1A 1AA, United Kingdom",
        "expected_unit": "5",
        "expected_house_number": "11",
        "expected_road": "HIGH STREET",
    },
    {
        "fixture_name": "APARTMENT_NAMED_BUILDING",
        "parser_input": (
            "Apartment 25, The Convent, 4 College Street, Oxford, OX1 1AA, United Kingdom"
        ),
        "expected_unit": "25",
        "expected_house_number": "4",
        "expected_road": "COLLEGE STREET",
    },
    {
        "fixture_name": "ALPHANUMERIC_UNIT_AND_BUILDING",
        "parser_input": "Flat 5A, 11B High Street, London, SW1A 1AA, United Kingdom",
        "expected_unit": "5A",
        "expected_house_number": "11B",
        "expected_road": "HIGH STREET",
    },
    {
        "fixture_name": "BUILDING_NUMBER_RANGE",
        "parser_input": "Flat 5, 11-13 High Street, London, SW1A 1AA, United Kingdom",
        "expected_unit": "5",
        "expected_house_number": "11-13",
        "expected_road": "HIGH STREET",
    },
    {
        "fixture_name": "SWAPPED_ROLE_CONTROL",
        "parser_input": "Flat 11, 5 High Street, London, SW1A 1AA, United Kingdom",
        "expected_unit": "11",
        "expected_house_number": "5",
        "expected_road": "HIGH STREET",
    },
    {
        "fixture_name": "UNIT_BLOCK_AND_BUILDING",
        "parser_input": (
            "Unit 2, Building 5, 11 High Street, London, SW1A 1AA, United Kingdom"
        ),
        "expected_unit": "2",
        "expected_house_number": "11",
        "expected_road": "HIGH STREET",
    },
)


class ResourceMonitor:
    def __init__(self, disk_path: Path, interval_seconds: float = 0.05) -> None:
        self.disk_path = disk_path
        self.interval_seconds = interval_seconds
        self.process = psutil.Process()
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.initial_rss_bytes = self.process.memory_info().rss
        self.peak_rss_bytes = self.initial_rss_bytes
        self.initial_free_disk_bytes = shutil.disk_usage(disk_path).free
        self.minimum_free_disk_bytes = self.initial_free_disk_bytes

    def _run(self) -> None:
        while not self.stop_event.wait(self.interval_seconds):
            self.peak_rss_bytes = max(self.peak_rss_bytes, self.process.memory_info().rss)
            self.minimum_free_disk_bytes = min(
                self.minimum_free_disk_bytes,
                shutil.disk_usage(self.disk_path).free,
            )

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> dict[str, int]:
        self.stop_event.set()
        self.thread.join()
        final_rss = self.process.memory_info().rss
        final_free_disk = shutil.disk_usage(self.disk_path).free
        self.peak_rss_bytes = max(self.peak_rss_bytes, final_rss)
        self.minimum_free_disk_bytes = min(self.minimum_free_disk_bytes, final_free_disk)
        return {
            "initial_process_rss_bytes": self.initial_rss_bytes,
            "peak_process_rss_bytes": self.peak_rss_bytes,
            "final_process_rss_bytes": final_rss,
            "initial_free_disk_bytes": self.initial_free_disk_bytes,
            "minimum_free_disk_bytes": self.minimum_free_disk_bytes,
            "final_free_disk_bytes": final_free_disk,
        }


def normalise_component(value: Any) -> str | None:
    if value is None or pd.isna(value):
        return None
    normalised = NON_ALNUM.sub(" ", str(value).upper()).strip()
    return normalised or None


def first_number_token(value: Any) -> str | None:
    normalised = normalise_component(value)
    if normalised is None:
        return None
    match = NUMBER_TOKEN.search(normalised)
    return match.group(1) if match else None


def canonical_role_component(value: Any, *, unit: bool = False) -> str | None:
    if value is None or pd.isna(value):
        return None
    normalised = str(value).upper().strip()
    if unit:
        normalised = UNIT_PREFIX.sub("", normalised)
    canonical = re.sub(r"[^A-Z0-9/-]+", "", normalised)
    return canonical or None


def number_designator(value: Any) -> str | None:
    if value is None or pd.isna(value):
        return None
    match = NUMBER_DESIGNATOR.search(str(value).upper())
    return re.sub(r"[ ]+", "", match.group(1)) if match else None


def combine_parsed_components(parsed: list[tuple[str, str]]) -> dict[str, str]:
    grouped: dict[str, list[str]] = defaultdict(list)
    for component, label in parsed:
        grouped[str(label)].append(str(component))
    return {label: " ".join(values) for label, values in grouped.items()}


def evaluate_parsed_row(
    parser_input: str,
    expected_house_number: str | None,
    expected_unit: str | None,
    expected_road: str | None,
    parse_address: Callable[[str], list[tuple[str, str]]],
) -> dict[str, Any]:
    parsed = combine_parsed_components(parse_address(parser_input))
    parsed_house_number = parsed.get("house_number")
    parsed_house = parsed.get("house")
    parsed_unit = parsed.get("unit")
    parsed_road = parsed.get("road")
    house_designator = number_designator(parsed_house_number)
    unit_comparison = canonical_role_component(parsed_unit, unit=True)
    parsed_paon_comparison = canonical_role_component(
        " ".join(value for value in (parsed_house, parsed_house_number) if value)
    )
    road_comparison = normalise_component(parsed_road)
    expected_road_comparison = normalise_component(expected_road)
    expected_house_designator = number_designator(expected_house_number)
    expected_paon_comparison = canonical_role_component(expected_house_number)
    expected_unit_comparison = canonical_role_component(expected_unit, unit=True)
    roles_differ = (
        expected_house_designator is not None
        and expected_house_designator != number_designator(expected_unit)
    )
    road_compatible = (
        road_comparison is not None
        and expected_road_comparison is not None
        and (
            expected_road_comparison in road_comparison
        )
    )

    return {
        "parsed_components_json": json.dumps(parsed, sort_keys=True, ensure_ascii=False),
        "parsed_house": parsed_house,
        "parsed_house_number": parsed_house_number,
        "parsed_unit": parsed_unit,
        "parsed_road": parsed_road,
        "parsed_house_number_designator": house_designator,
        "parsed_paon_comparison": parsed_paon_comparison,
        "parsed_unit_comparison": unit_comparison,
        "parsed_road_comparison": road_comparison,
        "house_number_present": parsed_house_number is not None,
        "unit_present": parsed_unit is not None,
        "road_present": parsed_road is not None,
        "house_number_matches_expected": house_designator == expected_house_designator,
        "paon_full_matches_expected": parsed_paon_comparison == expected_paon_comparison,
        "unit_matches_expected": unit_comparison == expected_unit_comparison,
        "road_matches_expected": road_comparison == expected_road_comparison,
        "road_compatible_with_expected": road_compatible,
        "role_swap": (
            roles_differ
            and house_designator == number_designator(expected_unit)
            and unit_comparison == expected_house_designator
        ),
        "number_roles_recovered": (
            house_designator == expected_house_designator
            and unit_comparison == expected_unit_comparison
        ),
        "compatible_candidate_recovered": (
            house_designator == expected_house_designator
            and unit_comparison == expected_unit_comparison
            and road_compatible
        ),
        "strict_candidate_recovered": (
            house_designator == expected_house_designator
            and unit_comparison == expected_unit_comparison
            and road_comparison == expected_road_comparison
        ),
    }


def summarise_results(results: pd.DataFrame, elapsed_seconds: float) -> dict[str, Any]:
    row_count = len(results)

    def count(column: str) -> int:
        return int(results[column].fillna(False).astype(bool).sum())

    def rate(column: str) -> float | None:
        return count(column) / row_count if row_count else None

    return {
        "row_count": row_count,
        "elapsed_seconds": elapsed_seconds,
        "rows_per_second": row_count / elapsed_seconds if elapsed_seconds else None,
        "house_number_present_count": count("house_number_present"),
        "house_number_present_rate": rate("house_number_present"),
        "house_number_missing_count": row_count - count("house_number_present"),
        "unit_present_count": count("unit_present"),
        "unit_present_rate": rate("unit_present"),
        "unit_missing_count": row_count - count("unit_present"),
        "road_present_count": count("road_present"),
        "road_present_rate": rate("road_present"),
        "house_number_match_count": count("house_number_matches_expected"),
        "house_number_match_rate": rate("house_number_matches_expected"),
        "house_number_present_but_mismatched_count": (
            count("house_number_present") - count("house_number_matches_expected")
        ),
        "full_paon_match_count": count("paon_full_matches_expected"),
        "full_paon_match_rate": rate("paon_full_matches_expected"),
        "unit_match_count": count("unit_matches_expected"),
        "unit_match_rate": rate("unit_matches_expected"),
        "unit_present_but_mismatched_count": (
            count("unit_present") - count("unit_matches_expected")
        ),
        "road_match_count": count("road_matches_expected"),
        "road_match_rate": rate("road_matches_expected"),
        "road_compatible_count": count("road_compatible_with_expected"),
        "road_compatible_rate": rate("road_compatible_with_expected"),
        "road_compatible_but_not_exact_count": (
            count("road_compatible_with_expected") - count("road_matches_expected")
        ),
        "role_swap_count": count("role_swap"),
        "role_swap_rate": rate("role_swap"),
        "number_roles_recovered_count": count("number_roles_recovered"),
        "number_roles_recovered_rate": rate("number_roles_recovered"),
        "compatible_candidate_recovered_count": count("compatible_candidate_recovered"),
        "compatible_candidate_recovered_rate": rate("compatible_candidate_recovered"),
        "strict_candidate_recovered_count": count("strict_candidate_recovered"),
        "strict_candidate_recovered_rate": rate("strict_candidate_recovered"),
        "parse_error_count": int(results["parse_error"].notna().sum()),
    }


def _benchmark_sample_query() -> str:
    return r"""
        with current_run as (
            select identity_run_key
            from identity.int_identity_current_run
        ),

        epc_flat as (
            select
                observation.identity_run_key,
                observation.identity_run_observation_key,
                observation.source_record_key as epc_source_record_key,
                observation.postcode,
                observation.premise_address_comparison,
                certificate.address1,
                certificate.address2,
                certificate.address3,
                regexp_extract_all(
                    observation.premise_address_comparison,
                    '(^| )([0-9]+[A-Z]?)',
                    2
                ) as number_tokens
            from identity.int_identity_observation as observation
            inner join current_run using (identity_run_key)
            inner join silver.stg_epc_certificate_observation as certificate
                on observation.source_record_key = certificate.source_record_key
            where
                observation.source_dataset = 'EPC_CERTIFICATE'
                and observation.is_identity_eligible
                and regexp_matches(
                    observation.premise_address_comparison,
                    '(^| )(FLAT|APARTMENT|APT|UNIT|ROOM|MAISONETTE) '
                    '[0-9]+[A-Z]? .* [0-9]+[A-Z]?'
                )
                and not regexp_matches(
                    upper(coalesce(certificate.address1, '')),
                    '(FLAT|APARTMENT|APT|UNIT|ROOM|MAISONETTE) '
                    '[0-9]+[A-Z]? *[-/] *[0-9]+'
                )
        ),

        pp_structured as (
            select
                source_record_key as pp_source_record_key,
                postcode,
                paon,
                saon,
                street,
                regexp_extract(upper(paon), '(^| )([0-9]+[A-Z]?)', 2) as paon_token,
                regexp_extract(upper(saon), '(^| )([0-9]+[A-Z]?)', 2) as saon_token,
                nullif(
                    trim(
                        regexp_replace(
                            regexp_replace(upper(street), '[^A-Z0-9]+', ' ', 'g'),
                            '\s+',
                            ' ',
                            'g'
                        )
                    ),
                    ''
                ) as street_comparison,
                nullif(
                    trim(
                        regexp_replace(
                            regexp_replace(
                                upper(concat_ws(' ', paon, saon, street, locality)),
                                '[^A-Z0-9]+',
                                ' ',
                                'g'
                            ),
                            '\s+',
                            ' ',
                            'g'
                        )
                    ),
                    ''
                ) as premise_address_comparison
            from silver.stg_pp_transaction_observation
            where
                postcode_parse_status = 'VALID'
                and paon is not null
                and saon is not null
                and street is not null
        ),

        aligned as (
            select
                epc.identity_run_key,
                epc.identity_run_observation_key,
                epc.epc_source_record_key,
                pp.pp_source_record_key,
                epc.postcode,
                epc.address1,
                epc.address2,
                epc.address3,
                concat_ws(
                    ', ',
                    epc.address1,
                    epc.address2,
                    epc.address3,
                    epc.postcode,
                    'United Kingdom'
                ) as parser_input,
                epc.number_tokens[1] as alignment_unit_token,
                epc.number_tokens[2] as alignment_house_number_token,
                pp.paon as expected_house_number,
                pp.saon as expected_unit,
                pp.street as expected_road,
                pp.street_comparison as expected_road_comparison,
                epc.premise_address_comparison = pp.premise_address_comparison
                    as current_exact_address_block,
                row_number() over (
                    partition by epc.identity_run_observation_key
                    order by sha256(pp.pp_source_record_key)
                ) as pp_choice_rank
            from epc_flat as epc
            inner join pp_structured as pp
                on
                    epc.postcode = pp.postcode
                    and epc.number_tokens[1] = pp.saon_token
                    and epc.number_tokens[2] = pp.paon_token
                    and contains(epc.premise_address_comparison, pp.street_comparison)
        ),

        one_pp_per_epc as (
            select
                * exclude (pp_choice_rank),
                count(*) over () as weak_label_population_count
            from aligned
            where pp_choice_rank = 1
        )

        select *
        from one_pp_per_epc
        order by sha256(concat(?, epc_source_record_key))
        limit ?
    """


def extract_benchmark_sample(
    database_path: Path,
    sample_size: int,
    sample_seed: str,
) -> pd.DataFrame:
    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        connection.execute("set threads = 1")
        connection.execute("set memory_limit = '8GB'")
        return connection.execute(
            _benchmark_sample_query(),
            [sample_seed, sample_size],
        ).fetchdf()
    finally:
        connection.close()


def _load_libpostal_parser(library_path: Path) -> Callable[[str], list[tuple[str, str]]]:
    if not library_path.is_file():
        raise FileNotFoundError(f"libpostal shared library not found: {library_path}")
    ctypes.CDLL(str(library_path), mode=ctypes.RTLD_GLOBAL)
    try:
        from postal.parser import parse_address
    except ImportError as error:
        raise RuntimeError(
            "Python package 'postal' is not installed; run the pinned benchmark setup"
        ) from error
    return parse_address


def parse_benchmark(
    sample: pd.DataFrame,
    parse_address: Callable[[str], list[tuple[str, str]]],
) -> tuple[pd.DataFrame, dict[str, Any]]:
    process = psutil.Process()
    peak_rss = process.memory_info().rss
    records: list[dict[str, Any]] = []
    started = time.perf_counter()
    for index, row in enumerate(sample.itertuples(index=False), start=1):
        record = row._asdict()
        try:
            record.update(
                evaluate_parsed_row(
                    str(row.parser_input),
                    row.expected_house_number,
                    row.expected_unit,
                    row.expected_road,
                    parse_address,
                )
            )
            record["parse_error"] = None
        except Exception as error:  # pragma: no cover - native parser failures are retained
            record.update(
                {
                    "parsed_components_json": None,
                    "parsed_house": None,
                    "parsed_house_number": None,
                    "parsed_unit": None,
                    "parsed_road": None,
                    "parsed_house_number_designator": None,
                    "parsed_paon_comparison": None,
                    "parsed_unit_comparison": None,
                    "parsed_road_comparison": None,
                    "house_number_present": False,
                    "unit_present": False,
                    "road_present": False,
                    "house_number_matches_expected": False,
                    "paon_full_matches_expected": False,
                    "unit_matches_expected": False,
                    "road_matches_expected": False,
                    "road_compatible_with_expected": False,
                    "role_swap": False,
                    "number_roles_recovered": False,
                    "compatible_candidate_recovered": False,
                    "strict_candidate_recovered": False,
                    "parse_error": f"{type(error).__name__}: {error}",
                }
            )
        records.append(record)
        if index % 100 == 0:
            peak_rss = max(peak_rss, process.memory_info().rss)
    elapsed = time.perf_counter() - started
    results = pd.DataFrame.from_records(records)
    metrics = summarise_results(results, elapsed)
    metrics["peak_process_rss_bytes"] = peak_rss
    return results, metrics


def evaluate_synthetic_fixtures(
    parse_address: Callable[[str], list[tuple[str, str]]],
) -> pd.DataFrame:
    records = []
    for fixture in SYNTHETIC_FIXTURES:
        evaluated = dict(fixture)
        try:
            evaluated.update(
                evaluate_parsed_row(
                    fixture["parser_input"],
                    fixture["expected_house_number"],
                    fixture["expected_unit"],
                    fixture["expected_road"],
                    parse_address,
                )
            )
            evaluated["parse_error"] = None
        except Exception as error:  # pragma: no cover
            evaluated["parse_error"] = f"{type(error).__name__}: {error}"
        records.append(evaluated)
    return pd.DataFrame.from_records(records)


def _fanout_summary(values: pd.Series) -> dict[str, Any]:
    if values.empty:
        return {"row_count": 0}
    return {
        "row_count": len(values),
        "total_pair_count": int(values.sum()),
        "zero_pair_count": int((values == 0).sum()),
        "positive_pair_count": int((values > 0).sum()),
        "minimum": int(values.min()),
        "median": float(values.quantile(0.5)),
        "p90": float(values.quantile(0.9)),
        "p99": float(values.quantile(0.99)),
        "maximum": int(values.max()),
        "over_20_count": int((values > 20).sum()),
        "over_100_count": int((values > 100).sum()),
    }


def evaluate_candidate_fanout(database_path: Path, results: pd.DataFrame) -> dict[str, Any]:
    parsed = results.loc[
        results["parse_error"].isna()
        & results["parsed_house_number_designator"].notna()
        & results["parsed_unit_comparison"].notna()
        & results["parsed_road_comparison"].notna(),
        [
            "identity_run_observation_key",
            "postcode",
            "parsed_house_number_designator",
            "parsed_unit_comparison",
            "parsed_road_comparison",
        ],
    ].copy()
    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        connection.execute("set threads = 1")
        connection.execute("set memory_limit = '4GB'")
        connection.register("parsed_libpostal_benchmark", parsed)
        fanout = connection.execute(
            r"""
            with pp as (
                select
                    postcode,
                    nullif(
                        regexp_replace(
                            regexp_extract(
                                upper(paon),
                                '([0-9]+[A-Z]?([ ]*-[ ]*[0-9]+[A-Z]?)?)',
                                1
                            ),
                            '[ ]+',
                            '',
                            'g'
                        ),
                        ''
                    ) as paon_designator,
                    nullif(
                        regexp_replace(
                            regexp_replace(
                                upper(saon),
                                '^(FLAT|APARTMENT|APT|UNIT|ROOM|MAISONETTE)[ ]*',
                                ''
                            ),
                            '[^A-Z0-9/-]+',
                            '',
                            'g'
                        ),
                        ''
                    ) as saon_comparison,
                    nullif(
                        trim(
                            regexp_replace(
                                regexp_replace(upper(street), '[^A-Z0-9]+', ' ', 'g'),
                                '\s+',
                                ' ',
                                'g'
                            )
                        ),
                        ''
                    ) as street_comparison
                from silver.stg_pp_transaction_observation
                where
                    postcode_parse_status = 'VALID'
                    and paon is not null
                    and street is not null
            )

            select
                parsed.identity_run_observation_key,
                count(pp.postcode) filter (
                    where parsed.parsed_road_comparison = pp.street_comparison
                ) as building_only_pair_count,
                count(pp.postcode) filter (
                    where pp.saon_comparison = parsed.parsed_unit_comparison
                      and parsed.parsed_road_comparison = pp.street_comparison
                ) as full_component_pair_count
                ,count(pp.postcode) filter (
                    where contains(parsed.parsed_road_comparison, pp.street_comparison)
                ) as compatible_building_only_pair_count
                ,count(pp.postcode) filter (
                    where pp.saon_comparison = parsed.parsed_unit_comparison
                      and (
                          contains(parsed.parsed_road_comparison, pp.street_comparison)
                      )
                ) as compatible_full_component_pair_count
            from parsed_libpostal_benchmark as parsed
            left join pp
                on
                    parsed.postcode = pp.postcode
                    and parsed.parsed_house_number_designator = pp.paon_designator
            group by parsed.identity_run_observation_key
            """
        ).fetchdf()
    finally:
        connection.close()
    return {
        "parsed_rows_evaluated": len(parsed),
        "building_only": _fanout_summary(fanout["building_only_pair_count"]),
        "full_unit_building": _fanout_summary(fanout["full_component_pair_count"]),
        "compatible_road_building_only": _fanout_summary(
            fanout["compatible_building_only_pair_count"]
        ),
        "compatible_road_full_unit_building": _fanout_summary(
            fanout["compatible_full_component_pair_count"]
        ),
        "building_only_cross_unit_excess_pair_count": int(
            (fanout["building_only_pair_count"] - fanout["full_component_pair_count"]).sum()
        ),
        "compatible_road_cross_unit_excess_pair_count": int(
            (
                fanout["compatible_building_only_pair_count"]
                - fanout["compatible_full_component_pair_count"]
            ).sum()
        ),
    }


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _add_framed_bytes(digest: Any, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, byteorder="big", signed=False))
    digest.update(value)


def fingerprint_directory(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    total_size = 0
    for file_path in sorted(candidate for candidate in path.rglob("*") if candidate.is_file()):
        relative_path = file_path.relative_to(path).as_posix().encode()
        _add_framed_bytes(digest, relative_path)
        digest.update(file_path.stat().st_size.to_bytes(8, byteorder="big", signed=False))
        with file_path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                total_size += len(chunk)
                digest.update(chunk)
    return digest.hexdigest(), total_size


def fingerprint_frame(frame: pd.DataFrame) -> str:
    digest = hashlib.sha256()
    for column in frame.columns:
        _add_framed_bytes(digest, str(column).encode())
    for row in frame.itertuples(index=False, name=None):
        for value in row:
            serialised = b"<NULL>" if pd.isna(value) else str(value).encode()
            _add_framed_bytes(digest, serialised)
    return digest.hexdigest()


def fingerprint_files(paths: list[Path], root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        _add_framed_bytes(digest, path.relative_to(root).as_posix().encode())
        digest.update(path.stat().st_size.to_bytes(8, byteorder="big", signed=False))
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    return digest.hexdigest()


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def installed_artifact_evidence(
    library_path: Path,
    data_root: Path,
) -> dict[str, Any]:
    resolved_library = library_path.resolve(strict=True)
    postal_spec = importlib.util.find_spec("postal")
    if postal_spec is None or not postal_spec.submodule_search_locations:
        raise RuntimeError("Python package 'postal' is not installed")
    postal_root = Path(next(iter(postal_spec.submodule_search_locations)))
    extension_files = sorted(postal_root.glob("*.so"))
    if not extension_files:
        raise RuntimeError(f"No pypostal extension files found under {postal_root}")
    model_sha256, model_size = fingerprint_directory(data_root)
    return {
        "libpostal_library_path": str(resolved_library),
        "libpostal_library_sha256": file_sha256(resolved_library),
        "pypostal_extension_root": str(postal_root),
        "pypostal_extension_file_count": len(extension_files),
        "pypostal_extensions_sha256": fingerprint_files(extension_files, postal_root),
        "libpostal_model_data_sha256": model_sha256,
        "libpostal_model_data_bytes": model_size,
    }


def verify_install_manifest(
    manifest_path: Path,
    actual: dict[str, Any],
    libpostal_commit: str,
    pypostal_commit: str,
    model_variant: str,
) -> dict[str, Any]:
    if not manifest_path.is_file():
        raise FileNotFoundError(
            f"Pinned libpostal install manifest not found: {manifest_path}; "
            "run make libpostal-setup"
        )
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected = {
        "libpostal_commit": libpostal_commit,
        "pypostal_commit": pypostal_commit,
        "model_variant": model_variant,
        "libpostal_library_sha256": actual["libpostal_library_sha256"],
        "pypostal_extensions_sha256": actual["pypostal_extensions_sha256"],
        "libpostal_model_data_sha256": actual["libpostal_model_data_sha256"],
    }
    mismatches = {
        key: {"manifest": manifest.get(key), "actual": value}
        for key, value in expected.items()
        if manifest.get(key) != value
    }
    if mismatches:
        raise RuntimeError(
            f"Installed libpostal artifacts do not match their manifest: {mismatches}"
        )
    return manifest


def git_worktree_evidence(project_root: Path) -> dict[str, Any]:
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=project_root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    status = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=project_root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return {"git_commit": commit, "git_worktree_dirty": bool(status.strip())}


def create_immutable_output_directory(output_root: Path, benchmark_key: str) -> Path:
    output_root.mkdir(parents=True, exist_ok=True)
    output_directory = output_root / benchmark_key
    output_directory.mkdir(exist_ok=False)
    return output_directory


def run_benchmark(args: argparse.Namespace) -> Path:
    project_root = Path(__file__).resolve().parents[2]
    monitor = ResourceMonitor(args.database.resolve().parent)
    monitor.start()
    total_started = time.perf_counter()
    resource_metrics: dict[str, int] | None = None
    try:
        sample_started = time.perf_counter()
        sample = extract_benchmark_sample(args.database, args.sample_size, args.sample_seed)
        sample_extraction_seconds = time.perf_counter() - sample_started
        if len(sample) != args.sample_size:
            raise RuntimeError(f"Expected {args.sample_size} benchmark rows, found {len(sample)}")
        sample_sha256 = fingerprint_frame(sample)

        fingerprint_started = time.perf_counter()
        artifact_evidence = installed_artifact_evidence(args.library, args.data_root)
        model_fingerprint_seconds = time.perf_counter() - fingerprint_started
        install_manifest = verify_install_manifest(
            args.install_manifest,
            artifact_evidence,
            args.libpostal_commit,
            args.pypostal_commit,
            args.model_variant,
        )
        implementation_files = [
            Path(__file__).resolve(),
            project_root / "scripts/setup_libpostal_benchmark.sh",
            project_root / "pyproject.toml",
        ]
        implementation_sha256 = fingerprint_files(implementation_files, project_root)
        git_evidence = git_worktree_evidence(project_root)
        identity_run_key = str(sample["identity_run_key"].iloc[0])
        benchmark_key = stable_sha256(
            "epc-v4.identity.libpostal-benchmark",
            "v2",
            [
                identity_run_key,
                BENCHMARK_CONTRACT_VERSION,
                args.sample_seed,
                str(args.sample_size),
                sample_sha256,
                implementation_sha256,
                args.libpostal_commit,
                args.pypostal_commit,
                artifact_evidence["libpostal_library_sha256"],
                artifact_evidence["pypostal_extensions_sha256"],
                artifact_evidence["libpostal_model_data_sha256"],
                str(artifact_evidence["libpostal_model_data_bytes"]),
            ],
        )
        if (args.output_root / benchmark_key).exists():
            raise FileExistsError(f"Immutable benchmark output already exists: {benchmark_key}")

        rss_before_load = psutil.Process().memory_info().rss
        parser_load_started = time.perf_counter()
        parse_address = _load_libpostal_parser(args.library)
        parser_load_seconds = time.perf_counter() - parser_load_started
        rss_after_load = psutil.Process().memory_info().rss

        results, parsing_metrics = parse_benchmark(sample, parse_address)
        fixtures = evaluate_synthetic_fixtures(parse_address)
        fanout_started = time.perf_counter()
        fanout_metrics = evaluate_candidate_fanout(args.database, results)
        fanout_seconds = time.perf_counter() - fanout_started
        resource_metrics = monitor.stop()
    finally:
        if resource_metrics is None:
            monitor.stop()

    output_directory = create_immutable_output_directory(args.output_root, benchmark_key)
    parsed_sample_path = output_directory / "parsed_sample.csv"
    fixture_path = output_directory / "synthetic_fixtures.csv"
    results.to_csv(parsed_sample_path, index=False)
    fixtures.to_csv(fixture_path, index=False)
    parsed_sample_sha256 = file_sha256(parsed_sample_path)
    fixture_sha256 = file_sha256(fixture_path)
    report = {
        "benchmark_key": benchmark_key,
        "benchmark_contract_version": BENCHMARK_CONTRACT_VERSION,
        "created_at": datetime.now(UTC).isoformat(),
        "database_path": str(args.database.resolve()),
        "identity_run_key": identity_run_key,
        "sample_seed": args.sample_seed,
        "sample_size": args.sample_size,
        "weak_label_population_count": int(sample["weak_label_population_count"].iloc[0]),
        "selected_sample_sha256": sample_sha256,
        "weak_label_basis": (
            "Same-postcode EPC unit/building token order aligned to PPD SAON/PAON with "
            "PPD street text present in the EPC comparison address"
        ),
        "weak_label_warning": "Benchmark alignments are plausible candidates, not manual labels",
        "weak_label_exclusions": "Numeric unit ranges in EPC address line 1 are excluded",
        "weak_label_scope_warning": (
            "Rates apply only to an explicit-unit, ordered-number, same-postcode, "
            "PPD-aligned stratum and must not be generalised to all EPC addresses"
        ),
        "artifact_classification": "RESTRICTED_IDENTITY_REVIEW",
        "artifact_disclosure_status": "DO_NOT_PUBLISH_SOURCE_ADDRESSES",
        "artifact_retention_status": "LOCAL_REVIEW_REQUIRED",
        "contains_source_addresses": True,
        "libpostal_commit": args.libpostal_commit,
        "pypostal_commit": args.pypostal_commit,
        "pypostal_package_version": importlib.metadata.version("postal"),
        "libpostal_model_variant": args.model_variant,
        **artifact_evidence,
        "install_manifest_path": str(args.install_manifest.resolve()),
        "install_manifest_contract_version": install_manifest["manifest_contract_version"],
        "implementation_sha256": implementation_sha256,
        **git_evidence,
        "platform": platform.platform(),
        "python_version": platform.python_version(),
        "parser_load_seconds": parser_load_seconds,
        "sample_extraction_seconds": sample_extraction_seconds,
        "candidate_fanout_seconds": fanout_seconds,
        "model_fingerprint_seconds": model_fingerprint_seconds,
        "total_benchmark_seconds": time.perf_counter() - total_started,
        "rss_before_parser_load_bytes": rss_before_load,
        "rss_after_parser_load_bytes": rss_after_load,
        "whole_run_resource_metrics": resource_metrics,
        "parsing_metrics": parsing_metrics,
        "candidate_fanout": fanout_metrics,
        "candidate_fanout_grain": "PPD transaction observation pairs per sampled EPC observation",
        "candidate_fanout_cohort": (
            "Rows where libpostal emitted house-number, unit and road components"
        ),
        "parsed_sample_sha256": parsed_sample_sha256,
        "synthetic_fixtures_sha256": fixture_sha256,
        "synthetic_fixture_count": len(fixtures),
        "synthetic_strict_recovery_count": int(
            fixtures["strict_candidate_recovered"].fillna(False).sum()
        ),
    }
    report_path = output_directory / "report.json"
    _write_json(report_path, report)
    _write_json(
        output_directory / "artifact_manifest.json",
        {
            "benchmark_key": benchmark_key,
            "artifact_manifest_contract_version": "libpostal_benchmark_artifacts_v1",
            "artifacts": {
                "parsed_sample.csv": parsed_sample_sha256,
                "synthetic_fixtures.csv": fixture_sha256,
                "report.json": file_sha256(report_path),
            },
        },
    )
    return output_directory


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a shadow libpostal EPC/PPD benchmark")
    parser.add_argument(
        "--database",
        type=Path,
        default=Path("output/duckdb/epc_v4.duckdb"),
    )
    parser.add_argument("--sample-size", type=int, default=10_000)
    parser.add_argument("--sample-seed", default=DEFAULT_SAMPLE_SEED)
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path("output/identity/libpostal_benchmark"),
    )
    parser.add_argument(
        "--library",
        type=Path,
        default=Path.home() / ".local/lib/libpostal.so",
    )
    parser.add_argument(
        "--data-root",
        type=Path,
        default=Path.home() / ".local/share/libpostal",
    )
    parser.add_argument("--model-variant", default="default")
    parser.add_argument(
        "--install-manifest",
        type=Path,
        default=Path.home() / ".local/share/epc-v4-libpostal-install.json",
    )
    parser.add_argument("--libpostal-commit", default=LIBPOSTAL_COMMIT)
    parser.add_argument("--pypostal-commit", default=PYPPOSTAL_COMMIT)
    args = parser.parse_args()
    if args.sample_size < 1:
        parser.error("--sample-size must be positive")
    if not args.database.is_file():
        parser.error(f"Database not found: {args.database}")
    if not args.data_root.is_dir():
        parser.error(f"libpostal data directory not found: {args.data_root}")
    if not args.install_manifest.is_file():
        parser.error(f"libpostal install manifest not found: {args.install_manifest}")
    return args


def main() -> None:
    output_directory = run_benchmark(parse_args())
    print(output_directory)


if __name__ == "__main__":
    main()
