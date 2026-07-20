from __future__ import annotations

import hashlib
import uuid
from pathlib import Path

import duckdb
import pytest

from epc_v5.address_components import parse_address_components
from epc_v5.parse_identity_addresses import (
    PARSER_INPUT_CONTRACT_VERSION,
    SELECTOR_CONTRACT_VERSION,
    SelectiveParseConfig,
    run_selective_address_parse,
)
from epc_v5.stable_keys import stable_sha256


def _fake_parser(_: str) -> list[tuple[str, str]]:
    return [("flat 5", "unit"), ("11", "house_number"), ("high street", "road")]


def test_active_component_parser_retains_ordered_and_canonical_evidence() -> None:
    parsed = parse_address_components("ignored", _fake_parser)

    assert parsed["parse_status"] == "COMPLETE"
    assert parsed["unit_identifier_comparison"] == "5"
    assert parsed["building_number_designator"] == "11"
    assert parsed["road_comparison"] == "HIGH STREET"
    assert '"ordinal": 1' in parsed["ordered_components_json"]


def _create_route_fixture(tmp_path) -> tuple[Path, SelectiveParseConfig, dict[str, object]]:
    database = tmp_path / "fixture.duckdb"
    connection = duckdb.connect(str(database))
    connection.execute("create schema silver")
    connection.execute(
        """
        create table silver.int_epc_address_libpostal_route_manifest (
            selector_contract_version varchar,
            parser_input_contract_version varchar,
            route_population_fingerprint varchar,
            routed_observation_count ubigint,
            distinct_parser_input_count ubigint
        )
        """
    )
    connection.execute(
        """
        insert into silver.int_epc_address_libpostal_route_manifest
        values (?, ?, ?, 2, 1)
        """,
        [
            SELECTOR_CONTRACT_VERSION,
            PARSER_INPUT_CONTRACT_VERSION,
            stable_sha256(
                "epc-v5.identity.address-parser-route-population",
                "v1",
                [
                    SELECTOR_CONTRACT_VERSION,
                    PARSER_INPUT_CONTRACT_VERSION,
                    "2",
                    hashlib.sha256(b"route-1route-2").hexdigest(),
                ],
            ),
        ],
    )
    connection.execute(
        """
        create table silver.int_epc_address_libpostal_route (
            route_selection_key varchar,
            source_record_key varchar,
            dataset_release_id uuid,
            source_file_id uuid,
            source_row_number ubigint,
            parser_input_key varchar,
            parser_input varchar,
            selection_reason varchar
        )
        """
    )
    release_id = uuid.uuid4()
    file_id = uuid.uuid4()
    connection.executemany(
        """
        insert into silver.int_epc_address_libpostal_route
        values (?, ?, ?, ?, ?, 'input-key', ?, 'EXPLICIT_UNIT_MULTI_NUMBER')
        """,
        [
            ("route-1", "source-1", release_id, file_id, 1, "Flat 5, 11 High Street"),
            ("route-2", "source-2", release_id, file_id, 2, "Flat 5, 11 High Street"),
        ],
    )
    connection.close()

    config = SelectiveParseConfig(
        database_path=database,
        batch_size=1,
        temp_directory=tmp_path / "temp",
    )
    evidence = {
        "libpostal_library_sha256": "library-sha",
        "pypostal_extensions_sha256": "extension-sha",
        "libpostal_model_data_sha256": "model-sha",
        "libpostal_model_data_bytes": 123,
    }
    return database, config, evidence


def test_selective_parser_deduplicates_inputs_and_is_idempotent(tmp_path) -> None:
    database, config, evidence = _create_route_fixture(tmp_path)

    first = run_selective_address_parse(
        config,
        parse_address=_fake_parser,
        artifact_evidence=evidence,
    )
    second = run_selective_address_parse(
        config,
        parse_address=_fake_parser,
        artifact_evidence=evidence,
    )

    assert first.selected_observation_count == 2
    assert first.distinct_input_count == 1
    assert first.parsed_result_count == 1
    assert first.reused_result_count == 0
    assert second.address_parse_run_key == first.address_parse_run_key
    assert second.reused_result_count == 1

    connection = duckdb.connect(str(database), read_only=True)
    assert connection.execute(
        "select count(*) from identity.identity_address_parse_request"
    ).fetchone()[0] == 2
    assert connection.execute(
        "select count(*) from identity.identity_address_parse_result"
    ).fetchone()[0] == 1
    assert connection.execute(
        "select address_parse_run_key from identity.identity_address_parse_publication"
    ).fetchone()[0] == first.address_parse_run_key
    connection.close()


def test_selective_parser_retries_errors_before_publication(tmp_path) -> None:
    database, config, evidence = _create_route_fixture(tmp_path)
    call_count = 0

    def flaky_parser(value: str) -> list[tuple[str, str]]:
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            raise ValueError("transient fixture failure")
        return _fake_parser(value)

    with pytest.raises(RuntimeError, match="retained 1 errors"):
        run_selective_address_parse(
            config,
            parse_address=flaky_parser,
            artifact_evidence=evidence,
        )

    summary = run_selective_address_parse(
        config,
        parse_address=flaky_parser,
        artifact_evidence=evidence,
    )
    assert summary.parsed_result_count == 1

    connection = duckdb.connect(str(database), read_only=True)
    assert connection.execute(
        "select count(*) from identity.identity_address_parse_error_attempt"
    ).fetchone()[0] == 1
    assert connection.execute(
        """
        select list(attempt_status order by started_at)
        from identity.identity_address_parse_attempt
        """
    ).fetchone()[0] == ["FAILED", "SUCCEEDED"]
    assert connection.execute(
        "select address_parse_run_key from identity.identity_address_parse_publication"
    ).fetchone()[0] == summary.address_parse_run_key
    connection.close()
