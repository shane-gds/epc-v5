"""Selectively parse routed EPC addresses into versioned identity evidence."""

from __future__ import annotations

import argparse
import json
import logging
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import duckdb

from epc_v5.address_components import parse_address_components
from epc_v5.libpostal_runtime import (
    LIBPOSTAL_COMMIT,
    PYPPOSTAL_COMMIT,
    fingerprint_files,
    installed_artifact_evidence,
    load_libpostal_parser,
    verify_install_manifest,
)
from epc_v5.stable_keys import sql_literal, stable_sha256, stable_sha256_sql

LOGGER = logging.getLogger(__name__)
SELECTOR_CONTRACT_VERSION = "epc_flat_trap_route_v1"
PARSER_INPUT_CONTRACT_VERSION = "epc_address_lines_postcode_gb_v1"
PARSER_CONTRACT_VERSION = "libpostal_uk_flat_v1"


@dataclass(frozen=True)
class SelectiveParseConfig:
    database_path: Path = Path("output/duckdb/epc_v5.duckdb")
    library_path: Path = Path.home() / ".local/lib/libpostal.so"
    data_root: Path = Path.home() / ".local/share/libpostal"
    install_manifest_path: Path = Path.home() / ".local/share/epc-v5-libpostal-install.json"
    selector_contract_version: str = SELECTOR_CONTRACT_VERSION
    parser_input_contract_version: str = PARSER_INPUT_CONTRACT_VERSION
    parser_contract_version: str = PARSER_CONTRACT_VERSION
    batch_size: int = 5_000
    threads: int = 1
    memory_limit: str = "4GB"
    temp_directory: Path = Path("output/tmp/libpostal_active")


@dataclass(frozen=True)
class ParseRunSummary:
    address_parse_run_id: uuid.UUID
    address_parse_run_key: str
    selected_observation_count: int
    distinct_input_count: int
    parsed_result_count: int
    parse_error_count: int
    reused_result_count: int


def _now() -> datetime:
    return datetime.now(UTC)


def _uuid_from_key(key: str) -> uuid.UUID:
    return uuid.UUID(key[:32])


def _implementation_sha256(project_root: Path) -> str:
    files = [
        project_root / "src/epc_v5/address_components.py",
        project_root / "src/epc_v5/libpostal_runtime.py",
        project_root / "src/epc_v5/parse_identity_addresses.py",
        project_root / "src/epc_v5/stable_keys.py",
        project_root / "macros/stable_sha256.sql",
        project_root / "models/silver/int_epc_address_libpostal_route.sql",
        project_root / "models/silver/int_epc_address_libpostal_route_manifest.sql",
        project_root / "scripts/setup_libpostal_benchmark.sh",
        project_root / "pyproject.toml",
    ]
    return fingerprint_files(files, project_root)


def _runtime_artifact_key(evidence: dict[str, Any]) -> str:
    return stable_sha256(
        "epc-v5.identity.address-parser-runtime",
        "v1",
        [
            "libpostal",
            LIBPOSTAL_COMMIT,
            PYPPOSTAL_COMMIT,
            evidence["libpostal_library_sha256"],
            evidence["pypostal_extensions_sha256"],
            evidence["libpostal_model_data_sha256"],
            evidence["libpostal_model_data_bytes"],
        ],
    )


def _create_tables(connection: duckdb.DuckDBPyConnection) -> None:
    connection.execute("create schema if not exists identity")
    connection.execute(
        """
        create table if not exists identity.identity_address_parse_run (
            address_parse_run_id uuid primary key,
            address_parse_run_key varchar not null unique,
            selector_contract_version varchar not null,
            parser_input_contract_version varchar not null,
            parser_contract_version varchar not null,
            route_population_fingerprint varchar not null,
            expected_request_count ubigint not null,
            distinct_input_count ubigint not null,
            runtime_artifact_key varchar not null,
            implementation_sha256 varchar not null,
            runtime_evidence_json json not null,
            parsed_result_count ubigint,
            parse_error_count ubigint,
            started_at timestamptz not null,
            completed_at timestamptz,
            run_status varchar not null,
            failure_message varchar
        )
        """
    )
    connection.execute(
        """
        create table if not exists identity.identity_address_parse_attempt (
            address_parse_attempt_id uuid primary key,
            address_parse_run_key varchar not null,
            started_at timestamptz not null,
            completed_at timestamptz,
            attempt_status varchar not null,
            batch_size uinteger not null,
            threads uinteger not null,
            memory_limit varchar not null,
            new_result_count ubigint,
            reused_result_count ubigint,
            elapsed_seconds double,
            failure_message varchar
        )
        """
    )
    connection.execute(
        """
        create table if not exists identity.identity_address_parse_publication (
            publication_name varchar primary key,
            address_parse_run_key varchar not null,
            published_at timestamptz not null
        )
        """
    )
    connection.execute(
        """
        create table if not exists identity.identity_address_parse_publication_event (
            publication_event_id uuid primary key,
            publication_name varchar not null,
            address_parse_run_key varchar not null,
            published_at timestamptz not null
        )
        """
    )
    connection.execute(
        """
        create table if not exists identity.identity_address_parse_request (
            address_parse_request_key varchar primary key,
            address_parse_run_id uuid not null,
            address_parse_run_key varchar not null,
            route_selection_key varchar not null,
            source_record_key varchar not null,
            dataset_release_id uuid not null,
            source_file_id uuid not null,
            source_row_number ubigint not null,
            parser_input_key varchar not null,
            parser_input varchar not null,
            selection_reason varchar not null,
            address_parse_result_key varchar not null,
            requested_at timestamptz not null,
            unique (address_parse_run_key, route_selection_key)
        )
        """
    )
    connection.execute(
        """
        create table if not exists identity.identity_address_parse_result (
            address_parse_result_key varchar primary key,
            parser_input_key varchar not null,
            parser_contract_version varchar not null,
            runtime_artifact_key varchar not null,
            implementation_sha256 varchar not null,
            ordered_components_json json,
            grouped_components_json json,
            parsed_house varchar,
            parsed_house_number varchar,
            parsed_unit varchar,
            parsed_road varchar,
            building_number_designator varchar,
            unit_identifier_comparison varchar,
            road_comparison varchar,
            parse_status varchar not null,
            parse_error varchar,
            parsed_at timestamptz not null
        )
        """
    )
    connection.execute(
        """
        create table if not exists identity.identity_address_parse_error_attempt (
            parse_error_attempt_id uuid primary key,
            address_parse_attempt_id uuid not null,
            address_parse_run_key varchar not null,
            address_parse_result_key varchar not null,
            parser_input_key varchar not null,
            parse_error varchar not null,
            failed_at timestamptz not null
        )
        """
    )


def _route_manifest(
    connection: duckdb.DuckDBPyConnection, config: SelectiveParseConfig
) -> tuple[str, int, int]:
    rows = connection.execute(
        """
        select route_population_fingerprint, routed_observation_count, distinct_parser_input_count
        from silver.int_epc_address_libpostal_route_manifest
        where selector_contract_version = ? and parser_input_contract_version = ?
        """,
        [config.selector_contract_version, config.parser_input_contract_version],
    ).fetchall()
    if len(rows) != 1:
        raise RuntimeError(
            "Expected one current selective libpostal route manifest, "
            f"found {len(rows)}"
        )
    manifest_fingerprint = str(rows[0][0])
    manifest_count = int(rows[0][1])
    manifest_distinct_count = int(rows[0][2])
    route_count, distinct_count, route_key_digest = connection.execute(
        """
        select
            count(*),
            count(distinct parser_input_key),
            coalesce(
                sha256(string_agg(route_selection_key, '' order by route_selection_key)),
                sha256('')
            )
        from silver.int_epc_address_libpostal_route
        """
    ).fetchone()
    computed_fingerprint = stable_sha256(
        "epc-v5.identity.address-parser-route-population",
        "v1",
        [
            config.selector_contract_version,
            config.parser_input_contract_version,
            str(route_count),
            str(route_key_digest),
        ],
    )
    if (
        int(route_count) != manifest_count
        or int(distinct_count) != manifest_distinct_count
        or computed_fingerprint != manifest_fingerprint
    ):
        raise RuntimeError(
            "Selective parser route differs from its materialized manifest; "
            "rebuild both route models together"
        )
    return computed_fingerprint, int(route_count), int(distinct_count)


def _publish_parse_run(
    connection: duckdb.DuckDBPyConnection,
    run_key: str,
    published_at: datetime,
) -> None:
    publication_name = "CURRENT_IDENTITY"
    connection.execute(
        """
        insert or replace into identity.identity_address_parse_publication
        values (?, ?, ?)
        """,
        [publication_name, run_key, published_at],
    )
    connection.execute(
        """
        insert into identity.identity_address_parse_publication_event
        values (?, ?, ?, ?)
        """,
        [uuid.uuid4(), publication_name, run_key, published_at],
    )


def _insert_requests(
    connection: duckdb.DuckDBPyConnection,
    run_id: uuid.UUID,
    run_key: str,
    config: SelectiveParseConfig,
    runtime_artifact_key: str,
    implementation_sha256: str,
) -> None:
    result_key = stable_sha256_sql(
        "epc-v5.identity.address-parse-result",
        "v1",
        [
            "route.parser_input_key",
            sql_literal(config.parser_contract_version),
            sql_literal(runtime_artifact_key),
            sql_literal(implementation_sha256),
        ],
    )
    request_key = stable_sha256_sql(
        "epc-v5.identity.address-parse-request",
        "v1",
        [sql_literal(run_key), "route.route_selection_key"],
    )
    connection.execute(
        f"""
        insert into identity.identity_address_parse_request
        select
            {request_key} as address_parse_request_key,
            uuid {sql_literal(str(run_id))} as address_parse_run_id,
            {sql_literal(run_key)} as address_parse_run_key,
            route.route_selection_key,
            route.source_record_key,
            route.dataset_release_id,
            route.source_file_id,
            route.source_row_number,
            route.parser_input_key,
            route.parser_input,
            route.selection_reason,
            {result_key} as address_parse_result_key,
            current_timestamp as requested_at
        from silver.int_epc_address_libpostal_route as route
        where not exists (
            select 1
            from identity.identity_address_parse_request as existing
            where existing.address_parse_run_key = {sql_literal(run_key)}
              and existing.route_selection_key = route.route_selection_key
        )
        """
    )


def _parse_pending_results(
    connection: duckdb.DuckDBPyConnection,
    run_key: str,
    config: SelectiveParseConfig,
    parse_address: Callable[[str], list[tuple[str, str]]],
    runtime_artifact_key: str,
    implementation_sha256: str,
    attempt_id: uuid.UUID,
) -> int:
    inserted = 0
    last_result_key = ""
    insert_sql = """
        insert into identity.identity_address_parse_result values (
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
    """
    while True:
        pending = connection.execute(
            """
            select distinct
                request.address_parse_result_key,
                request.parser_input_key,
                request.parser_input
            from identity.identity_address_parse_request as request
            left join identity.identity_address_parse_result as result
                on request.address_parse_result_key = result.address_parse_result_key
            where request.address_parse_run_key = ?
              and request.address_parse_result_key > ?
              and result.address_parse_result_key is null
            order by request.address_parse_result_key
            limit ?
            """,
            [run_key, last_result_key, config.batch_size],
        ).fetchall()
        if not pending:
            break
        outcomes = []
        errors = []
        for result_key, parser_input_key, parser_input in pending:
            try:
                parsed = parse_address_components(str(parser_input), parse_address)
            except Exception as error:  # pragma: no cover - native failures are retained
                errors.append(
                    (
                        uuid.uuid4(),
                        attempt_id,
                        run_key,
                        result_key,
                        parser_input_key,
                        f"{type(error).__name__}: {error}"[:1000],
                        _now(),
                    )
                )
                continue
            outcomes.append(
                (
                    result_key,
                    parser_input_key,
                    config.parser_contract_version,
                    runtime_artifact_key,
                    implementation_sha256,
                    parsed["ordered_components_json"],
                    parsed["grouped_components_json"],
                    parsed["parsed_house"],
                    parsed["parsed_house_number"],
                    parsed["parsed_unit"],
                    parsed["parsed_road"],
                    parsed["building_number_designator"],
                    parsed["unit_identifier_comparison"],
                    parsed["road_comparison"],
                    parsed["parse_status"],
                    None,
                    _now(),
                )
            )
        connection.execute("begin transaction")
        try:
            if outcomes:
                connection.executemany(insert_sql, outcomes)
            if errors:
                connection.executemany(
                    """
                    insert into identity.identity_address_parse_error_attempt
                    values (?, ?, ?, ?, ?, ?, ?)
                    """,
                    errors,
                )
            connection.execute("commit")
        except Exception:
            connection.execute("rollback")
            raise
        inserted += len(outcomes)
        last_result_key = str(pending[-1][0])
        LOGGER.info("Persisted %s new selective parse results", f"{inserted:,}")
        if errors:
            raise RuntimeError(
                f"Selective parser retained {len(errors):,} errors in attempt {attempt_id}"
            )
    return inserted


def run_selective_address_parse(
    config: SelectiveParseConfig,
    *,
    parse_address: Callable[[str], list[tuple[str, str]]] | None = None,
    artifact_evidence: dict[str, Any] | None = None,
) -> ParseRunSummary:
    """Parse the current routed population and publish only after complete closure."""
    if config.batch_size < 1 or config.threads < 1:
        raise ValueError("batch_size and threads must be positive")
    project_root = Path(__file__).resolve().parents[2]
    config.temp_directory.mkdir(parents=True, exist_ok=True)
    evidence = artifact_evidence or installed_artifact_evidence(
        config.library_path, config.data_root
    )
    if artifact_evidence is None:
        verify_install_manifest(config.install_manifest_path, evidence)
    runtime_artifact_key = _runtime_artifact_key(evidence)
    implementation_sha256 = _implementation_sha256(project_root)

    connection = duckdb.connect(str(config.database_path))
    connection.execute(f"set threads = {config.threads}")
    connection.execute("set memory_limit = ?", [config.memory_limit])
    connection.execute("set temp_directory = ?", [str(config.temp_directory)])
    connection.execute("set preserve_insertion_order = false")
    try:
        _create_tables(connection)
        route_fingerprint, expected_count, distinct_input_count = _route_manifest(
            connection, config
        )
    except Exception:
        connection.close()
        raise
    run_key = stable_sha256(
        "epc-v5.identity.address-parse-run",
        "v1",
        [
            route_fingerprint,
            config.selector_contract_version,
            config.parser_input_contract_version,
            config.parser_contract_version,
            runtime_artifact_key,
            implementation_sha256,
        ],
    )
    run_id = _uuid_from_key(run_key)
    existing = connection.execute(
        """
        select run_status, parsed_result_count, parse_error_count
        from identity.identity_address_parse_run
        where address_parse_run_key = ?
        """,
        [run_key],
    ).fetchone()
    if existing and existing[0] == "SUCCEEDED":
        request_count, result_count = connection.execute(
            """
            select
                count(*),
                count(distinct result.address_parse_result_key)
            from identity.identity_address_parse_request as request
            left join identity.identity_address_parse_result as result
                on request.address_parse_result_key = result.address_parse_result_key
            where request.address_parse_run_key = ?
            """,
            [run_key],
        ).fetchone()
        if int(request_count) != expected_count or int(result_count) != distinct_input_count:
            connection.close()
            raise RuntimeError("Successful selective parser run no longer satisfies closure")
        published_at = _now()
        connection.execute("begin transaction")
        try:
            _publish_parse_run(connection, run_key, published_at)
            connection.execute("commit")
        except Exception:
            connection.execute("rollback")
            connection.close()
            raise
        connection.close()
        return ParseRunSummary(
            run_id,
            run_key,
            expected_count,
            distinct_input_count,
            int(existing[1]),
            int(existing[2]),
            int(existing[1]),
        )

    started = _now()
    attempt_id = uuid.uuid4()
    if existing is None:
        connection.execute(
            """
            insert into identity.identity_address_parse_run values (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, null, null, ?, null, 'RUNNING', null
            )
            """,
            [
                run_id,
                run_key,
                config.selector_contract_version,
                config.parser_input_contract_version,
                config.parser_contract_version,
                route_fingerprint,
                expected_count,
                distinct_input_count,
                runtime_artifact_key,
                implementation_sha256,
                json.dumps(evidence, sort_keys=True),
                started,
            ],
        )
    else:
        connection.execute(
            """
            update identity.identity_address_parse_run
            set started_at = ?, completed_at = null, run_status = 'RUNNING',
                failure_message = null
            where address_parse_run_key = ?
            """,
            [started, run_key],
        )
    connection.execute(
        """
        insert into identity.identity_address_parse_attempt values (
            ?, ?, ?, null, 'RUNNING', ?, ?, ?, null, null, null, null
        )
        """,
        [
            attempt_id,
            run_key,
            started,
            config.batch_size,
            config.threads,
            config.memory_limit,
        ],
    )
    monotonic_started = time.perf_counter()
    try:
        _insert_requests(
            connection,
            run_id,
            run_key,
            config,
            runtime_artifact_key,
            implementation_sha256,
        )
        request_count = int(
            connection.execute(
                """
                select count(*) from identity.identity_address_parse_request
                where address_parse_run_key = ?
                """,
                [run_key],
            ).fetchone()[0]
        )
        if request_count != expected_count:
            raise RuntimeError(
                "Selective parser request closure failed: "
                f"expected {expected_count:,}, found {request_count:,}"
            )
        parser = parse_address or load_libpostal_parser(config.library_path)
        inserted_count = _parse_pending_results(
            connection,
            run_key,
            config,
            parser,
            runtime_artifact_key,
            implementation_sha256,
            attempt_id,
        )
        result_count, error_count = connection.execute(
            """
            select
                count(distinct request.address_parse_result_key),
                count(distinct request.address_parse_result_key)
                    filter (where result.parse_status = 'ERROR')
            from identity.identity_address_parse_request as request
            inner join identity.identity_address_parse_result as result
                on request.address_parse_result_key = result.address_parse_result_key
            where request.address_parse_run_key = ?
            """,
            [run_key],
        ).fetchone()
        if int(result_count) != distinct_input_count:
            raise RuntimeError(
                "Selective parser result closure failed: "
                f"expected {distinct_input_count:,}, found {int(result_count):,}"
            )
        completed = _now()
        elapsed = time.perf_counter() - monotonic_started
        reused_count = int(result_count) - inserted_count
        connection.execute("begin transaction")
        try:
            connection.execute(
                """
                update identity.identity_address_parse_run
                set parsed_result_count = ?, parse_error_count = ?, completed_at = ?,
                    run_status = 'SUCCEEDED', failure_message = null
                where address_parse_run_key = ?
                """,
                [result_count, error_count, completed, run_key],
            )
            connection.execute(
                """
                update identity.identity_address_parse_attempt
                set completed_at = ?, attempt_status = 'SUCCEEDED', new_result_count = ?,
                    reused_result_count = ?, elapsed_seconds = ?
                where address_parse_attempt_id = ?
                """,
                [completed, inserted_count, reused_count, elapsed, attempt_id],
            )
            _publish_parse_run(connection, run_key, completed)
            connection.execute("commit")
        except Exception:
            connection.execute("rollback")
            raise
        return ParseRunSummary(
            run_id,
            run_key,
            expected_count,
            distinct_input_count,
            int(result_count),
            int(error_count),
            reused_count,
        )
    except Exception as error:
        completed = _now()
        elapsed = time.perf_counter() - monotonic_started
        failure = f"{type(error).__name__}: {error}"[:4000]
        retained_error_count = connection.execute(
            """
            select count(*)
            from identity.identity_address_parse_error_attempt
            where address_parse_run_key = ?
            """,
            [run_key],
        ).fetchone()[0]
        connection.execute(
            """
            update identity.identity_address_parse_run
            set completed_at = ?, parse_error_count = ?, run_status = 'FAILED',
                failure_message = ?
            where address_parse_run_key = ?
            """,
            [completed, retained_error_count, failure, run_key],
        )
        connection.execute(
            """
            update identity.identity_address_parse_attempt
            set completed_at = ?, attempt_status = 'FAILED', elapsed_seconds = ?,
                failure_message = ?
            where address_parse_attempt_id = ?
            """,
            [completed, elapsed, failure, attempt_id],
        )
        raise
    finally:
        connection.close()


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, default=SelectiveParseConfig.database_path)
    parser.add_argument("--library", type=Path, default=SelectiveParseConfig.library_path)
    parser.add_argument("--data-root", type=Path, default=SelectiveParseConfig.data_root)
    parser.add_argument(
        "--install-manifest",
        type=Path,
        default=SelectiveParseConfig.install_manifest_path,
    )
    parser.add_argument("--batch-size", type=int, default=SelectiveParseConfig.batch_size)
    parser.add_argument("--threads", type=int, default=SelectiveParseConfig.threads)
    parser.add_argument("--memory-limit", default=SelectiveParseConfig.memory_limit)
    parser.add_argument(
        "--temp-directory", type=Path, default=SelectiveParseConfig.temp_directory
    )
    parser.add_argument("--log-level", default="INFO")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper()),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    summary = run_selective_address_parse(
        SelectiveParseConfig(
            database_path=args.database,
            library_path=args.library,
            data_root=args.data_root,
            install_manifest_path=args.install_manifest,
            batch_size=args.batch_size,
            threads=args.threads,
            memory_limit=args.memory_limit,
            temp_directory=args.temp_directory,
        )
    )
    print(summary.address_parse_run_key)


if __name__ == "__main__":
    main()
