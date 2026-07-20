from __future__ import annotations

import csv
import uuid
import zipfile
from dataclasses import replace
from pathlib import Path

import duckdb
import pytest
import yaml

import epc_v5.import_sources as import_sources
from epc_v5.import_sources import publish_silver_reconciliation, run_import


def _source_metadata(dataset_code: str, file_name: str) -> dict[str, object]:
    return {
        "dataset_code": dataset_code,
        "publisher": "Fixture Publisher",
        "release_label": "fixture-v1",
        "release_label_status": "TEST_FIXTURE",
        "release_date": None,
        "retrieval_status": "TEST_FIXTURE",
        "source_url": None,
        "licence_url": None,
        "licence_status": "TEST_FIXTURE",
        "file": file_name,
    }


def _write_config(root: Path, sources: dict[str, dict[str, object]]) -> Path:
    config_path = root / "config" / "source_import.yml"
    config_path.parent.mkdir()
    config = {
        "database_path": "output/test.duckdb",
        "data_root": "data",
        "temp_directory": "output/tmp",
        "memory_limit": "1GB",
        "threads": 1,
        "min_free_gib": 0,
        "sources": sources,
    }
    config_path.write_text(yaml.safe_dump(config), encoding="utf-8")
    return config_path


def test_pp_import_is_idempotent_and_preserves_empty_strings(tmp_path: Path) -> None:
    data_root = tmp_path / "data"
    data_root.mkdir()
    pp_path = data_root / "pp-complete.csv"
    rows = [
        ["tx-1", "100000", "2025-01-02 00:00", "S4 8GG"] + [""] * 12,
        ["tx-2", "125000", "2025-02-03 00:00", "S4 8GH"] + [""] * 12,
    ]
    with pp_path.open("w", encoding="utf-8", newline="") as handle:
        csv.writer(handle, quoting=csv.QUOTE_ALL).writerows(rows)
    config_path = _write_config(tmp_path, {"pp": _source_metadata("PPD_FIXTURE", pp_path.name)})
    database_path = tmp_path / "output" / "test.duckdb"

    run_import(config_path=config_path, targets=("pp",))
    run_import(config_path=config_path, targets=("pp",))

    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        assert (
            connection.execute("select count(*) from bronze.raw_pp_transaction").fetchone()[0] == 2
        )
        assert connection.execute(
            "select paon_raw from bronze.raw_pp_transaction order by source_row_number"
        ).fetchall() == [("",), ("",)]
        assert (
            connection.execute(
                "select count(distinct source_record_key) from bronze.raw_pp_transaction"
            ).fetchone()[0]
            == 2
        )
        assert (
            connection.execute(
                "select count(*) from audit.audit_pipeline_run where run_status = 'SUCCEEDED'"
            ).fetchone()[0]
            == 2
        )
    finally:
        connection.close()


def test_archive_members_load_separately_and_temporary_files_are_removed(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "data"
    data_root.mkdir()
    archive_path = data_root / "domestic-csv.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr(
            "certificates-2026.csv",
            "certificate_number,address,postcode\ncert-1,12 Merton Lane,S4 8GG\n",
        )
        archive.writestr(
            "recommendations-2026.csv",
            "certificate_number,improvement_item,improvement_id,indicative_cost\n"
            "cert-1,1,6,GBP 100 - GBP 350\n",
        )
    config_path = _write_config(
        tmp_path, {"epc": _source_metadata("EPC_FIXTURE", archive_path.name)}
    )
    database_path = tmp_path / "output" / "test.duckdb"

    run_import(config_path=config_path, targets=("epc",))

    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        assert connection.execute(
            "select certificate_number_raw from bronze.raw_epc_certificate"
        ).fetchall() == [("cert-1",)]
        assert connection.execute(
            "select improvement_id_raw from bronze.raw_epc_recommendation"
        ).fetchall() == [("6",)]
        assert (
            connection.execute(
                """
            select count(*)
            from audit.audit_source_file
            where file_kind = 'ZIP_MEMBER_CSV' and ingestion_status = 'LOADED'
            """
            ).fetchone()[0]
            == 2
        )
    finally:
        connection.close()

    assert list((tmp_path / "output" / "tmp").iterdir()) == []


def test_loaded_archive_rejects_member_parser_drift(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    data_root = tmp_path / "data"
    data_root.mkdir()
    archive_path = data_root / "domestic-csv.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr(
            "certificates-2026.csv",
            "certificate_number,address,postcode\ncert-1,12 Merton Lane,S4 8GG\n",
        )
    config_path = _write_config(
        tmp_path, {"epc": _source_metadata("EPC_FIXTURE", archive_path.name)}
    )
    run_import(config_path=config_path, targets=("epc",))

    changed_routes = tuple(
        replace(route, parser_contract_version=f"{route.parser_contract_version}_changed")
        for route in import_sources.ROUTES["epc"]
    )
    monkeypatch.setitem(import_sources.ROUTES, "epc", changed_routes)

    with pytest.raises(RuntimeError, match="member set or parser contract drift"):
        run_import(config_path=config_path, targets=("epc",))


def test_repacked_archive_reuses_member_content_without_reloading(tmp_path: Path) -> None:
    data_root = tmp_path / "data"
    data_root.mkdir()
    member_content = "certificate_number,address,postcode\ncert-1,12 Merton Lane,S4 8GG\n"
    first_archive = data_root / "domestic-first.zip"
    with zipfile.ZipFile(first_archive, "w") as archive:
        archive.writestr("certificates-2026.csv", member_content)
    config_path = _write_config(
        tmp_path, {"epc": _source_metadata("EPC_FIXTURE", first_archive.name)}
    )
    database_path = tmp_path / "output" / "test.duckdb"
    run_import(config_path=config_path, targets=("epc",))

    second_archive = data_root / "domestic-repacked.zip"
    with zipfile.ZipFile(second_archive, "w") as archive:
        archive.writestr("certificates-2026.csv", member_content)
        archive.writestr("ignored-metadata.txt", "repacked")
    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    config["sources"]["epc"]["file"] = second_archive.name
    config_path.write_text(yaml.safe_dump(config), encoding="utf-8")
    run_import(config_path=config_path, targets=("epc",))

    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        assert connection.execute(
            "select count(*) from bronze.raw_epc_certificate"
        ).fetchone()[0] == 1
        assert connection.execute(
            "select count(*) from audit.audit_source_file where file_kind = 'ZIP_MEMBER_CSV'"
        ).fetchone()[0] == 1
        assert connection.execute(
            "select count(*) from audit.audit_source_file_container"
        ).fetchone()[0] == 2
    finally:
        connection.close()


def test_archive_member_header_failure_is_terminal(tmp_path: Path) -> None:
    data_root = tmp_path / "data"
    data_root.mkdir()
    archive_path = data_root / "domestic-csv.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr("certificates-2026.csv", "")
    config_path = _write_config(
        tmp_path, {"epc": _source_metadata("EPC_FIXTURE", archive_path.name)}
    )
    database_path = tmp_path / "output" / "test.duckdb"

    with pytest.raises(StopIteration):
        run_import(config_path=config_path, targets=("epc",))

    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        assert connection.execute(
            "select file_kind, ingestion_status from audit.audit_source_file order by file_kind"
        ).fetchall() == [("ZIP_ARCHIVE", "PARTIAL"), ("ZIP_MEMBER_CSV", "FAILED")]
        assert connection.execute(
            "select status from audit.audit_dataset_release"
        ).fetchone()[0] == "PARTIAL"
    finally:
        connection.close()


def test_headed_reference_import_validates_schema_and_preserves_source_values(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "data"
    data_root.mkdir()
    reference_path = data_root / "lad.csv"
    with reference_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["LAD25CD", "LAD25NM", "LAD25NMW", "ObjectId"])
        writer.writerow(["W06000001", "Isle of Anglesey", "Ynys Môn", "1"])
        writer.writerow(["E06000001", "Hartlepool", "", "2"])
    source = _source_metadata("ONS_LAD_NAMES_CODES_FIXTURE", reference_path.name)
    config_path = _write_config(tmp_path, {"lad_reference": source})
    database_path = tmp_path / "output" / "test.duckdb"

    run_import(config_path=config_path, targets=("lad_reference",))
    run_import(config_path=config_path, targets=("lad_reference",))

    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        rows = connection.execute(
            """
            select lad25cd_raw, lad25nm_raw, lad25nmw_raw
            from bronze.raw_lad_name_code
            order by source_row_number
            """
        ).fetchall()
        assert rows == [
            ("W06000001", "Isle of Anglesey", "Ynys Môn"),
            ("E06000001", "Hartlepool", ""),
        ]
        assert connection.execute(
            "select count(distinct source_record_key) from bronze.raw_lad_name_code"
        ).fetchone()[0] == 2
    finally:
        connection.close()


def test_headed_reference_import_rejects_header_drift(tmp_path: Path) -> None:
    data_root = tmp_path / "data"
    data_root.mkdir()
    reference_path = data_root / "lad.csv"
    reference_path.write_text("LAD25CD,LAD25NM,ObjectId\nE06000001,Hartlepool,1\n")
    config_path = _write_config(
        tmp_path,
        {"lad_reference": _source_metadata("ONS_LAD_NAMES_CODES_FIXTURE", reference_path.name)},
    )

    with pytest.raises(RuntimeError, match="Source header drift"):
        run_import(config_path=config_path, targets=("lad_reference",))

    connection = duckdb.connect(str(tmp_path / "output" / "test.duckdb"), read_only=True)
    try:
        assert connection.execute(
            """
            select ingestion_status, failure_message is not null
            from audit.audit_source_file
            """
        ).fetchone() == ("FAILED", True)
    finally:
        connection.close()


def test_failed_header_manifest_allows_corrected_content_retry(tmp_path: Path) -> None:
    data_root = tmp_path / "data"
    data_root.mkdir()
    reference_path = data_root / "lad.csv"
    reference_path.write_bytes(b"")
    config_path = _write_config(
        tmp_path,
        {"lad_reference": _source_metadata("ONS_LAD_NAMES_CODES_FIXTURE", reference_path.name)},
    )
    database_path = tmp_path / "output" / "test.duckdb"

    with pytest.raises(RuntimeError):
        run_import(config_path=config_path, targets=("lad_reference",))

    reference_path.write_text(
        "LAD25CD,LAD25NM,LAD25NMW,ObjectId\nE06000001,Hartlepool,,1\n",
        encoding="utf-8",
    )
    run_import(config_path=config_path, targets=("lad_reference",))

    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        assert connection.execute(
            "select ingestion_status, count(*) from audit.audit_source_file group by 1 order by 1"
        ).fetchall() == [("FAILED", 1), ("LOADED", 1)]
        assert (
            connection.execute("select count(*) from bronze.raw_lad_name_code").fetchone()[0]
            == 1
        )
        assert connection.execute(
            "select status from audit.audit_dataset_release"
        ).fetchone()[0] == "LOADED"
    finally:
        connection.close()


def test_renamed_reference_content_is_not_loaded_twice(tmp_path: Path) -> None:
    data_root = tmp_path / "data"
    data_root.mkdir()
    first_path = data_root / "lad-first.csv"
    content = "LAD25CD,LAD25NM,LAD25NMW,ObjectId\nE06000001,Hartlepool,,1\n"
    first_path.write_text(content, encoding="utf-8")
    config_path = _write_config(
        tmp_path,
        {"lad_reference": _source_metadata("ONS_LAD_NAMES_CODES_FIXTURE", first_path.name)},
    )
    database_path = tmp_path / "output" / "test.duckdb"
    run_import(config_path=config_path, targets=("lad_reference",))

    second_path = data_root / "lad-renamed.csv"
    second_path.write_text(content, encoding="utf-8")
    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    config["sources"]["lad_reference"]["file"] = second_path.name
    config_path.write_text(yaml.safe_dump(config), encoding="utf-8")
    run_import(config_path=config_path, targets=("lad_reference",))

    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        assert (
            connection.execute("select count(*) from bronze.raw_lad_name_code").fetchone()[0]
            == 1
        )
        assert connection.execute("select count(*) from audit.audit_source_file").fetchone()[0] == 1
    finally:
        connection.close()


def test_reference_source_keys_are_release_sensitive(tmp_path: Path) -> None:
    data_root = tmp_path / "data"
    data_root.mkdir()
    reference_path = data_root / "lad.csv"
    reference_path.write_text(
        "LAD25CD,LAD25NM,LAD25NMW,ObjectId\nE06000001,Hartlepool,,1\n",
        encoding="utf-8",
    )
    config_path = _write_config(
        tmp_path,
        {"lad_reference": _source_metadata("ONS_LAD_NAMES_CODES_FIXTURE", reference_path.name)},
    )
    database_path = tmp_path / "output" / "test.duckdb"
    run_import(config_path=config_path, targets=("lad_reference",))

    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    config["sources"]["lad_reference"]["release_label"] = "fixture-v2"
    config_path.write_text(yaml.safe_dump(config), encoding="utf-8")
    run_import(config_path=config_path, targets=("lad_reference",))

    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        assert connection.execute(
            "select count(*), count(distinct source_record_key) from bronze.raw_lad_name_code"
        ).fetchone() == (2, 2)
    finally:
        connection.close()


def test_release_registration_rejects_metadata_drift(tmp_path: Path) -> None:
    data_root = tmp_path / "data"
    data_root.mkdir()
    reference_path = data_root / "lad.csv"
    reference_path.write_text(
        "LAD25CD,LAD25NM,LAD25NMW,ObjectId\nE06000001,Hartlepool,,1\n",
        encoding="utf-8",
    )
    config_path = _write_config(
        tmp_path,
        {"lad_reference": _source_metadata("ONS_LAD_NAMES_CODES_FIXTURE", reference_path.name)},
    )
    run_import(config_path=config_path, targets=("lad_reference",))

    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    config["sources"]["lad_reference"]["retrieval_status"] = "CHANGED_STATUS"
    config_path.write_text(yaml.safe_dump(config), encoding="utf-8")

    with pytest.raises(RuntimeError, match="Conflicting metadata registered for release"):
        run_import(config_path=config_path, targets=("lad_reference",))


def _create_reconciliation_fixture(database_path: Path, status: str) -> tuple[uuid.UUID, ...]:
    parent_id, first_id, second_id = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    connection = duckdb.connect(str(database_path))
    try:
        connection.execute("create schema audit")
        connection.execute(
            """
            create table audit.audit_source_file (
                source_file_id uuid,
                parent_source_file_id uuid,
                file_kind varchar,
                ingestion_status varchar,
                loaded_at timestamptz,
                accepted_row_count ubigint,
                quarantined_row_count ubigint
            )
            """
        )
        connection.execute(
            """
            create table audit.audit_source_file_silver_reconciliation (
                source_file_id uuid,
                silver_accepted_row_count ubigint,
                silver_quarantined_row_count ubigint,
                reconciliation_status varchar,
                reconciled_at timestamptz
            )
            """
        )
        connection.executemany(
            """
            insert into audit.audit_source_file
            values (?, ?, ?, 'LOADED', current_timestamp, 0, 0)
            """,
            [
                (parent_id, None, "ZIP_ARCHIVE"),
                (first_id, parent_id, "ZIP_MEMBER_CSV"),
                (second_id, parent_id, "ZIP_MEMBER_CSV"),
            ],
        )
        connection.executemany(
            """
            insert into audit.audit_source_file_silver_reconciliation
            values (?, ?, ?, ?, current_timestamp)
            """,
            [(first_id, 9, 1, status), (second_id, 20, 0, "PASSED")],
        )
    finally:
        connection.close()
    return parent_id, first_id, second_id


def test_publish_silver_reconciliation_updates_leaf_and_archive_counts(
    tmp_path: Path,
) -> None:
    database_path = tmp_path / "reconciliation.duckdb"
    parent_id, first_id, second_id = _create_reconciliation_fixture(database_path, "PASSED")

    assert publish_silver_reconciliation(database_path) == 2

    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        assert connection.execute(
            """
            select source_file_id, accepted_row_count, quarantined_row_count
            from audit.audit_source_file
            order by source_file_id
            """
        ).fetchall() == sorted(
            [(parent_id, 29, 1), (first_id, 9, 1), (second_id, 20, 0)],
            key=lambda row: row[0],
        )
    finally:
        connection.close()


def test_publish_silver_reconciliation_rejects_failed_files(tmp_path: Path) -> None:
    database_path = tmp_path / "reconciliation.duckdb"
    _create_reconciliation_fixture(database_path, "FAILED")

    with pytest.raises(RuntimeError, match=r"1 file\(s\) failed"):
        publish_silver_reconciliation(database_path)


def test_publish_silver_reconciliation_requires_complete_file_coverage(
    tmp_path: Path,
) -> None:
    database_path = tmp_path / "reconciliation.duckdb"
    _create_reconciliation_fixture(database_path, "PASSED")
    connection = duckdb.connect(str(database_path))
    try:
        connection.execute(
            """
            delete from audit.audit_source_file_silver_reconciliation
            where silver_accepted_row_count = 9
            """
        )
    finally:
        connection.close()

    with pytest.raises(RuntimeError, match="expected 2 loaded source files"):
        publish_silver_reconciliation(database_path)
