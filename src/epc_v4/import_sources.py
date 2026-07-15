"""Audited, bounded source ingestion into DuckDB Bronze tables."""

from __future__ import annotations

import csv
import hashlib
import json
import logging
import os
import re
import shutil
import uuid
import zipfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import duckdb
import yaml

from epc_v4.stable_keys import sql_literal, stable_sha256, stable_sha256_sql

LOGGER = logging.getLogger(__name__)
GIB = 1024**3

PP_COLUMNS = (
    "transaction_id_raw",
    "price_paid_raw",
    "transfer_date_raw",
    "postcode_raw",
    "property_type_raw",
    "old_new_raw",
    "duration_raw",
    "paon_raw",
    "saon_raw",
    "street_raw",
    "locality_raw",
    "town_city_raw",
    "district_raw",
    "county_raw",
    "category_raw",
    "record_status_raw",
)

LAD_REFERENCE_COLUMNS = ("LAD25CD", "LAD25NM", "LAD25NMW", "ObjectId")
LPA_REFERENCE_COLUMNS = ("LPA25CD", "LPA25NM", "Co_terminous", "ObjectId")


@dataclass(frozen=True)
class Route:
    member_pattern: re.Pattern[str] | None
    raw_table: str
    parser_contract_version: str
    source_key_namespace: str
    has_header: bool = True
    fixed_columns: tuple[str, ...] | None = None
    source_key_payload_version: str = "v1"
    source_key_includes_release: bool = False
    source_key_includes_member_path: bool = True


@dataclass(frozen=True)
class ImportSettings:
    database_path: Path
    data_root: Path
    temp_directory: Path
    memory_limit: str
    threads: int
    min_free_gib: int
    sources: dict[str, dict[str, Any]]


ROUTES: dict[str, tuple[Route, ...]] = {
    "pp": (
        Route(
            member_pattern=None,
            raw_table="raw_pp_transaction",
            parser_contract_version="pp_complete_csv_v1",
            source_key_namespace="uk.gov.landregistry.ppd.source-row",
            has_header=False,
            fixed_columns=PP_COLUMNS,
        ),
    ),
    "epc": (
        Route(
            member_pattern=re.compile(r"^certificates-\d{4}\.csv$"),
            raw_table="raw_epc_certificate",
            parser_contract_version="domestic_epc_certificate_csv_v1",
            source_key_namespace="uk.gov.epc.domestic-certificate.source-row",
        ),
        Route(
            member_pattern=re.compile(r"^recommendations-\d{4}\.csv$"),
            raw_table="raw_epc_recommendation",
            parser_contract_version="domestic_epc_recommendation_csv_v1",
            source_key_namespace="uk.gov.epc.domestic-recommendation.source-row",
        ),
    ),
    "onsud": (
        Route(
            member_pattern=re.compile(r"^Data/ONSUD_DEC_2025_[A-Z]{2}\.csv$"),
            raw_table="raw_onsud_uprn",
            parser_contract_version="onsud_dec_2025_csv_v1",
            source_key_namespace="uk.gov.ons.onsud.source-row",
        ),
    ),
    "lad_reference": (
        Route(
            member_pattern=None,
            raw_table="raw_lad_name_code",
            parser_contract_version="ons_lad_apr_2025_name_code_csv_v1",
            source_key_namespace="uk.gov.ons.lad-name-code.source-row",
            fixed_columns=LAD_REFERENCE_COLUMNS,
            source_key_payload_version="v2",
            source_key_includes_release=True,
            source_key_includes_member_path=False,
        ),
    ),
    "lpa_reference": (
        Route(
            member_pattern=None,
            raw_table="raw_lpa_name_code",
            parser_contract_version="ons_lpa_may_2025_name_code_csv_v1",
            source_key_namespace="uk.gov.ons.lpa-name-code.source-row",
            fixed_columns=LPA_REFERENCE_COLUMNS,
            source_key_payload_version="v2",
            source_key_includes_release=True,
            source_key_includes_member_path=False,
        ),
    ),
}

COMMON_RAW_COLUMNS = (
    "source_record_key",
    "dataset_release_id",
    "source_file_id",
    "parent_source_file_id",
    "source_member_path",
    "source_row_number",
    "pipeline_run_id",
    "parser_contract_version",
    "loaded_at",
)


def _now() -> datetime:
    return datetime.now(UTC)


def _quote_identifier(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def _qualified_table(schema: str, table: str) -> str:
    return f"{_quote_identifier(schema)}.{_quote_identifier(table)}"


def _normalize_column(value: str) -> str:
    normalized = re.sub(r"[^a-zA-Z0-9]+", "_", value.strip()).strip("_").lower()
    if not normalized:
        raise ValueError(f"Source column has no usable name: {value!r}")
    if normalized[0].isdigit():
        normalized = f"column_{normalized}"
    return normalized


def _raw_column_names(source_columns: tuple[str, ...], has_header: bool) -> tuple[str, ...]:
    if not has_header:
        return source_columns
    normalized = tuple(f"{_normalize_column(column)}_raw" for column in source_columns)
    if len(set(normalized)) != len(normalized):
        raise ValueError("Source header contains duplicate normalized column names")
    return normalized


def _read_header(path: Path) -> tuple[str, ...]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        row = next(csv.reader(handle))
    return tuple(row)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(16 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _ensure_free_space(path: Path, required_bytes: int, minimum_free_gib: int) -> None:
    free_bytes = shutil.disk_usage(path).free
    required = required_bytes + minimum_free_gib * GIB
    if free_bytes < required:
        raise RuntimeError(
            "Insufficient free space: "
            f"{free_bytes / GIB:.1f} GiB available, {required / GIB:.1f} GiB required"
        )


def load_settings(
    config_path: Path,
    database_path: Path | None = None,
    data_root: Path | None = None,
) -> ImportSettings:
    with config_path.open("r", encoding="utf-8") as handle:
        raw = yaml.safe_load(handle)

    project_root = config_path.resolve().parent.parent

    def resolve(value: str) -> Path:
        path = Path(value).expanduser()
        return path if path.is_absolute() else project_root / path

    return ImportSettings(
        database_path=(database_path or resolve(raw["database_path"])).resolve(),
        data_root=(data_root or resolve(raw["data_root"])).resolve(),
        temp_directory=resolve(raw["temp_directory"]).resolve(),
        memory_limit=str(raw["memory_limit"]),
        threads=int(raw["threads"]),
        min_free_gib=int(raw["min_free_gib"]),
        sources=dict(raw["sources"]),
    )


def _connect(settings: ImportSettings) -> duckdb.DuckDBPyConnection:
    settings.database_path.parent.mkdir(parents=True, exist_ok=True)
    settings.temp_directory.mkdir(parents=True, exist_ok=True)
    connection = duckdb.connect(str(settings.database_path))
    connection.execute(f"set memory_limit = {sql_literal(settings.memory_limit)}")
    connection.execute(f"set threads = {settings.threads}")
    connection.execute(f"set temp_directory = {sql_literal(str(settings.temp_directory))}")
    connection.execute("set preserve_insertion_order = true")
    return connection


def _create_control_tables(connection: duckdb.DuckDBPyConnection) -> None:
    connection.execute("create schema if not exists audit")
    connection.execute("create schema if not exists bronze")
    connection.execute(
        """
        create table if not exists audit.audit_dataset_release (
            dataset_release_id uuid primary key,
            dataset_code varchar not null,
            publisher varchar not null,
            release_label varchar not null,
            release_label_status varchar not null,
            release_date date,
            release_key varchar not null,
            retrieval_status varchar not null,
            source_url varchar,
            licence_url varchar,
            licence_status varchar not null,
            status varchar not null,
            registered_at timestamptz not null,
            loaded_at timestamptz
        )
        """
    )
    connection.execute(
        """
        create table if not exists audit.audit_pipeline_run (
            pipeline_run_id uuid primary key,
            code_revision varchar not null,
            command varchar not null,
            started_at timestamptz not null,
            completed_at timestamptz,
            run_status varchar not null,
            resource_profile json not null,
            target_summary json,
            failure_message varchar
        )
        """
    )
    connection.execute(
        """
        create table if not exists audit.audit_source_file (
            source_file_id uuid primary key,
            dataset_release_id uuid not null,
            parent_source_file_id uuid,
            registered_pipeline_run_id uuid not null,
            file_kind varchar not null,
            file_name varchar not null,
            source_path varchar not null,
            content_sha256 varchar not null,
            byte_size ubigint not null,
            zip_crc32 varchar,
            zip_compressed_size ubigint,
            parser_contract_version varchar not null,
            observed_row_count ubigint,
            accepted_row_count ubigint,
            quarantined_row_count ubigint,
            ingestion_status varchar not null,
            registered_at timestamptz not null,
            loaded_at timestamptz,
            failure_message varchar
        )
        """
    )
    connection.execute(
        """
        create table if not exists audit.audit_source_file_container (
            source_file_container_key varchar primary key,
            parent_source_file_id uuid not null,
            child_source_file_id uuid not null,
            source_member_path varchar not null,
            registered_pipeline_run_id uuid not null,
            registered_at timestamptz not null
        )
        """
    )
    membership_key = stable_sha256_sql(
        "epc-v4.audit.source-file-container",
        "v1",
        [
            "cast(parent_source_file_id as varchar)",
            "cast(source_file_id as varchar)",
            "file_name",
        ],
    )
    connection.execute(
        f"""
        insert into audit.audit_source_file_container by name
        select
            {membership_key} as source_file_container_key,
            parent_source_file_id,
            source_file_id as child_source_file_id,
            file_name as source_member_path,
            registered_pipeline_run_id,
            registered_at
        from audit.audit_source_file as child
        where parent_source_file_id is not null
          and not exists (
              select 1
              from audit.audit_source_file_container as membership
              where membership.parent_source_file_id = child.parent_source_file_id
                and membership.child_source_file_id = child.source_file_id
                and membership.source_member_path = child.file_name
          )
        """
    )


def _register_pipeline_run(
    connection: duckdb.DuckDBPyConnection,
    settings: ImportSettings,
    targets: tuple[str, ...],
) -> uuid.UUID:
    pipeline_run_id = uuid.uuid4()
    profile = json.dumps(
        {
            "memory_limit": settings.memory_limit,
            "threads": settings.threads,
            "temp_directory": str(settings.temp_directory),
            "min_free_gib": settings.min_free_gib,
        }
    )
    command = "python -m epc_v4 import-sources --targets " + " ".join(targets)
    connection.execute(
        """
        insert into audit.audit_pipeline_run values (?, ?, ?, ?, null, ?, ?, null, null)
        """,
        [pipeline_run_id, "UNVERSIONED_WORKTREE", command, _now(), "RUNNING", profile],
    )
    return pipeline_run_id


def _register_release(
    connection: duckdb.DuckDBPyConnection,
    source: dict[str, Any],
) -> uuid.UUID:
    release_key = stable_sha256(
        "epc-v4.audit.dataset-release",
        "v1",
        [source["publisher"], source["dataset_code"], source["release_label"]],
    )
    existing = connection.execute(
        """
        select dataset_release_id, dataset_code, publisher, release_label,
               release_label_status, release_date, retrieval_status, source_url,
               licence_url, licence_status
        from audit.audit_dataset_release
        where release_key = ?
        """,
        [release_key],
    ).fetchone()
    if existing:
        existing_metadata = list(existing[1:])
        if existing_metadata[4] is not None:
            existing_metadata[4] = existing_metadata[4].isoformat()
        supplied_date = source.get("release_date")
        supplied_metadata = [
            source["dataset_code"],
            source["publisher"],
            source["release_label"],
            source["release_label_status"],
            str(supplied_date) if supplied_date is not None else None,
            source["retrieval_status"],
            source.get("source_url"),
            source.get("licence_url"),
            source["licence_status"],
        ]
        if existing_metadata != supplied_metadata:
            raise RuntimeError(
                f"Conflicting metadata registered for release {release_key}: "
                f"existing={existing_metadata}, supplied={supplied_metadata}"
            )
        return existing[0]

    dataset_release_id = uuid.uuid4()
    connection.execute(
        """
        insert into audit.audit_dataset_release values (
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'REGISTERED', ?, null
        )
        """,
        [
            dataset_release_id,
            source["dataset_code"],
            source["publisher"],
            source["release_label"],
            source["release_label_status"],
            source.get("release_date"),
            release_key,
            source["retrieval_status"],
            source.get("source_url"),
            source.get("licence_url"),
            source["licence_status"],
            _now(),
        ],
    )
    return dataset_release_id


def _find_source_file(
    connection: duckdb.DuckDBPyConnection,
    dataset_release_id: uuid.UUID,
    file_name: str,
    parent_source_file_id: uuid.UUID | None,
) -> tuple[Any, ...] | None:
    return connection.execute(
        """
        select source_file_id, content_sha256, byte_size, zip_crc32,
               parser_contract_version, ingestion_status
        from audit.audit_source_file
        where dataset_release_id = ?
          and file_name = ?
          and parent_source_file_id is not distinct from ?
        order by registered_at desc
        limit 1
        """,
        [dataset_release_id, file_name, parent_source_file_id],
    ).fetchone()


def _register_container_membership(
    connection: duckdb.DuckDBPyConnection,
    *,
    parent_source_file_id: uuid.UUID | None,
    child_source_file_id: uuid.UUID,
    source_member_path: str,
    pipeline_run_id: uuid.UUID,
) -> None:
    if parent_source_file_id is None:
        return
    membership_key = stable_sha256(
        "epc-v4.audit.source-file-container",
        "v1",
        [str(parent_source_file_id), str(child_source_file_id), source_member_path],
    )
    connection.execute(
        """
        insert into audit.audit_source_file_container
        select ?, ?, ?, ?, ?, ?
        where not exists (
            select 1
            from audit.audit_source_file_container
            where source_file_container_key = ?
        )
        """,
        [
            membership_key,
            parent_source_file_id,
            child_source_file_id,
            source_member_path,
            pipeline_run_id,
            _now(),
            membership_key,
        ],
    )


def _register_source_file(
    connection: duckdb.DuckDBPyConnection,
    *,
    dataset_release_id: uuid.UUID,
    pipeline_run_id: uuid.UUID,
    parent_source_file_id: uuid.UUID | None,
    file_kind: str,
    file_name: str,
    source_path: str,
    content_sha256: str,
    byte_size: int,
    parser_contract_version: str,
    zip_crc32: str | None = None,
    zip_compressed_size: int | None = None,
) -> uuid.UUID:
    content_match = connection.execute(
        """
        select source_file_id, parser_contract_version
        from audit.audit_source_file
        where dataset_release_id = ?
          and content_sha256 = ?
          and byte_size = ?
        order by registered_at
        limit 1
        """,
        [dataset_release_id, content_sha256, byte_size],
    ).fetchone()
    if content_match:
        if content_match[1] != parser_contract_version:
            raise RuntimeError(
                f"Conflicting parser contract for content {content_sha256}: "
                f"existing={content_match[1]}, supplied={parser_contract_version}"
            )
        _register_container_membership(
            connection,
            parent_source_file_id=parent_source_file_id,
            child_source_file_id=content_match[0],
            source_member_path=file_name,
            pipeline_run_id=pipeline_run_id,
        )
        return content_match[0]

    source_file_id = uuid.uuid4()
    connection.execute(
        """
        insert into audit.audit_source_file values (
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, null, null, null,
            'REGISTERED', ?, null, null
        )
        """,
        [
            source_file_id,
            dataset_release_id,
            parent_source_file_id,
            pipeline_run_id,
            file_kind,
            file_name,
            source_path,
            content_sha256,
            byte_size,
            zip_crc32,
            zip_compressed_size,
            parser_contract_version,
            _now(),
        ],
    )
    _register_container_membership(
        connection,
        parent_source_file_id=parent_source_file_id,
        child_source_file_id=source_file_id,
        source_member_path=file_name,
        pipeline_run_id=pipeline_run_id,
    )
    return source_file_id


def _source_file_status(connection: duckdb.DuckDBPyConnection, source_file_id: uuid.UUID) -> str:
    row = connection.execute(
        "select ingestion_status from audit.audit_source_file where source_file_id = ?",
        [source_file_id],
    ).fetchone()
    if not row:
        raise RuntimeError(f"Missing source-file manifest {source_file_id}")
    return str(row[0])


def _mark_source_file_failed(
    connection: duckdb.DuckDBPyConnection,
    source_file_id: uuid.UUID,
    error: Exception | str,
) -> None:
    message = str(error) or type(error).__name__
    connection.execute(
        """
        update audit.audit_source_file
        set ingestion_status = 'FAILED', failure_message = ?
        where source_file_id = ? and ingestion_status <> 'LOADED'
        """,
        [message[:4000], source_file_id],
    )


def _ensure_raw_table(
    connection: duckdb.DuckDBPyConnection,
    table_name: str,
    raw_columns: tuple[str, ...],
) -> None:
    qualified = _qualified_table("bronze", table_name)
    source_columns_sql = ",\n".join(
        f"{_quote_identifier(column)} varchar not null" for column in raw_columns
    )
    connection.execute(
        f"""
        create table if not exists {qualified} (
            source_record_key varchar not null,
            dataset_release_id uuid not null,
            source_file_id uuid not null,
            parent_source_file_id uuid,
            source_member_path varchar not null,
            source_row_number ubigint not null,
            pipeline_run_id uuid not null,
            parser_contract_version varchar not null,
            loaded_at timestamptz not null,
            {source_columns_sql}
        )
        """
    )
    actual = tuple(
        row[0]
        for row in connection.execute(
            """
            select column_name
            from information_schema.columns
            where table_schema = 'bronze' and table_name = ?
            order by ordinal_position
            """,
            [table_name],
        ).fetchall()
    )
    expected = COMMON_RAW_COLUMNS + raw_columns
    if actual != expected:
        raise RuntimeError(
            f"Bronze schema drift for {table_name}: expected {expected}, found {actual}"
        )


def _csv_scan_sql(source_columns: tuple[str, ...], has_header: bool) -> str:
    columns = ", ".join(f"{sql_literal(column)}: 'VARCHAR'" for column in source_columns)
    force_not_null = ", ".join(sql_literal(column) for column in source_columns)
    return (
        "read_csv(?, "
        f"header={'true' if has_header else 'false'}, "
        f"columns={{{columns}}}, force_not_null=[{force_not_null}], "
        "auto_detect=false, delim=',', quote='\"', escape='\"', "
        "strict_mode=true, parallel=false, null_padding=false, max_line_size=16777216)"
    )


def _load_csv(
    connection: duckdb.DuckDBPyConnection,
    *,
    path: Path,
    source_columns: tuple[str, ...],
    route: Route,
    dataset_release_id: uuid.UUID,
    source_file_id: uuid.UUID,
    parent_source_file_id: uuid.UUID | None,
    source_member_path: str,
    content_sha256: str,
    pipeline_run_id: uuid.UUID,
) -> int:
    raw_columns = _raw_column_names(source_columns, route.has_header)
    qualified = _qualified_table("bronze", route.raw_table)
    source_projection = ",\n".join(
        f"source.{_quote_identifier(source)} as {_quote_identifier(raw)}"
        for source, raw in zip(source_columns, raw_columns, strict=True)
    )
    source_key_fields = [sql_literal(content_sha256)]
    if route.source_key_includes_release:
        release_key = connection.execute(
            "select release_key from audit.audit_dataset_release where dataset_release_id = ?",
            [dataset_release_id],
        ).fetchone()[0]
        source_key_fields.insert(0, sql_literal(str(release_key)))
    if route.source_key_includes_member_path:
        source_key_fields.append(sql_literal(source_member_path))
    source_key_fields.append("cast(source_row_number as varchar)")
    source_key = stable_sha256_sql(
        route.source_key_namespace,
        route.source_key_payload_version,
        source_key_fields,
    )
    parent_id_sql = (
        f"uuid {sql_literal(str(parent_source_file_id))}"
        if parent_source_file_id
        else "cast(null as uuid)"
    )
    scan = _csv_scan_sql(source_columns, route.has_header)
    loaded_at = _now().isoformat()
    insert_sql = f"""
        insert into {qualified} by name
        with source as (
            select * from {scan}
        ),
        numbered as (
            select cast(row_number() over () as ubigint) as source_row_number, *
            from source
        )
        select
            {source_key} as source_record_key,
            uuid {sql_literal(str(dataset_release_id))} as dataset_release_id,
            uuid {sql_literal(str(source_file_id))} as source_file_id,
            {parent_id_sql} as parent_source_file_id,
            {sql_literal(source_member_path)} as source_member_path,
            source_row_number,
            uuid {sql_literal(str(pipeline_run_id))} as pipeline_run_id,
            {sql_literal(route.parser_contract_version)} as parser_contract_version,
            cast({sql_literal(loaded_at)} as timestamptz) as loaded_at,
            {source_projection}
        from numbered as source
    """

    connection.execute("begin transaction")
    try:
        _ensure_raw_table(connection, route.raw_table, raw_columns)
        connection.execute(
            """
            update audit.audit_source_file
            set ingestion_status = 'LOADING', failure_message = null
            where source_file_id = ?
            """,
            [source_file_id],
        )
        inserted = int(connection.execute(insert_sql, [str(path)]).fetchone()[0])
        connection.execute(
            """
            update audit.audit_source_file
            set observed_row_count = ?, accepted_row_count = ?, quarantined_row_count = 0,
                ingestion_status = 'LOADED', loaded_at = ?, failure_message = null
            where source_file_id = ?
            """,
            [inserted, inserted, _now(), source_file_id],
        )
        connection.execute("commit")
        return inserted
    except Exception as error:
        connection.execute("rollback")
        _mark_source_file_failed(connection, source_file_id, error)
        raise


def _import_direct_file(
    connection: duckdb.DuckDBPyConnection,
    settings: ImportSettings,
    target_name: str,
    source: dict[str, Any],
    pipeline_run_id: uuid.UUID,
) -> dict[str, int]:
    route = ROUTES[target_name][0]
    path = settings.data_root / source["file"]
    if not path.is_file():
        raise FileNotFoundError(path)
    columns = route.fixed_columns
    if columns is None:
        raise RuntimeError(f"Direct route {target_name} has no fixed columns")
    _ensure_free_space(settings.database_path.parent, 0, settings.min_free_gib)
    LOGGER.info("Hashing %s", path)
    content_sha256 = _sha256_file(path)
    dataset_release_id = _register_release(connection, source)
    source_file_id = _register_source_file(
        connection,
        dataset_release_id=dataset_release_id,
        pipeline_run_id=pipeline_run_id,
        parent_source_file_id=None,
        file_kind="CSV",
        file_name=path.name,
        source_path=str(path),
        content_sha256=content_sha256,
        byte_size=path.stat().st_size,
        parser_contract_version=route.parser_contract_version,
    )
    if _source_file_status(connection, source_file_id) == "LOADED":
        LOGGER.info("Skipping already-loaded source %s", path.name)
        return {"loaded": 0, "skipped": 1}

    if route.has_header:
        try:
            observed_columns = _read_header(path)
            if observed_columns != columns:
                raise RuntimeError(
                    f"Source header drift for {path.name}: "
                    f"expected {columns}, found {observed_columns}"
                )
        except Exception as error:
            message = str(error) or type(error).__name__
            _mark_source_file_failed(connection, source_file_id, error)
            connection.execute(
                """
                update audit.audit_dataset_release
                set status = 'FAILED', loaded_at = null
                where dataset_release_id = ?
                """,
                [dataset_release_id],
            )
            raise RuntimeError(message) from error

    LOGGER.info("Loading %s into bronze.%s", path.name, route.raw_table)
    rows = _load_csv(
        connection,
        path=path,
        source_columns=columns,
        route=route,
        dataset_release_id=dataset_release_id,
        source_file_id=source_file_id,
        parent_source_file_id=None,
        source_member_path=path.name,
        content_sha256=content_sha256,
        pipeline_run_id=pipeline_run_id,
    )
    connection.execute(
        """
        update audit.audit_dataset_release
        set status = 'LOADED', loaded_at = ?
        where dataset_release_id = ?
        """,
        [_now(), dataset_release_id],
    )
    LOGGER.info("Loaded %s rows from %s", f"{rows:,}", path.name)
    return {"loaded": 1, "skipped": 0, "rows": rows}


def _route_for_member(target_name: str, member_name: str) -> Route | None:
    for route in ROUTES[target_name]:
        if route.member_pattern and route.member_pattern.fullmatch(member_name):
            return route
    return None


def _extract_member(
    archive: zipfile.ZipFile,
    member: zipfile.ZipInfo,
    destination: Path,
) -> str:
    digest = hashlib.sha256()
    with archive.open(member, "r") as source, destination.open("wb") as target:
        while chunk := source.read(16 * 1024 * 1024):
            target.write(chunk)
            digest.update(chunk)
    return digest.hexdigest()


def _finalize_archive_manifest(
    connection: duckdb.DuckDBPyConnection,
    archive_source_file_id: uuid.UUID,
    dataset_release_id: uuid.UUID,
) -> None:
    totals = connection.execute(
        """
        select count(*), coalesce(sum(child.observed_row_count), 0),
               coalesce(sum(child.accepted_row_count), 0),
               coalesce(sum(child.quarantined_row_count), 0),
               count(*) filter (where child.ingestion_status = 'LOADED')
        from audit.audit_source_file_container as membership
        inner join audit.audit_source_file as child
            on membership.child_source_file_id = child.source_file_id
        where membership.parent_source_file_id = ?
        """,
        [archive_source_file_id],
    ).fetchone()
    member_count, observed, accepted, quarantined, loaded_count = totals
    status = "LOADED" if member_count and member_count == loaded_count else "PARTIAL"
    connection.execute(
        """
        update audit.audit_source_file
        set observed_row_count = ?, accepted_row_count = ?, quarantined_row_count = ?,
            ingestion_status = ?, loaded_at = case when ? = 'LOADED' then ? else null end
        where source_file_id = ?
        """,
        [
            observed,
            accepted,
            quarantined,
            status,
            status,
            _now(),
            archive_source_file_id,
        ],
    )
    connection.execute(
        """
        update audit.audit_dataset_release
        set status = ?, loaded_at = case when ? = 'LOADED' then ? else null end
        where dataset_release_id = ?
        """,
        [status, status, _now(), dataset_release_id],
    )


def _import_archive(
    connection: duckdb.DuckDBPyConnection,
    settings: ImportSettings,
    target_name: str,
    source: dict[str, Any],
    pipeline_run_id: uuid.UUID,
) -> dict[str, int]:
    path = settings.data_root / source["file"]
    if not path.is_file():
        raise FileNotFoundError(path)
    LOGGER.info("Hashing archive %s", path)
    archive_sha256 = _sha256_file(path)
    dataset_release_id = _register_release(connection, source)
    archive_source_file_id = _register_source_file(
        connection,
        dataset_release_id=dataset_release_id,
        pipeline_run_id=pipeline_run_id,
        parent_source_file_id=None,
        file_kind="ZIP_ARCHIVE",
        file_name=path.name,
        source_path=str(path),
        content_sha256=archive_sha256,
        byte_size=path.stat().st_size,
        parser_contract_version="zip_archive_v1",
    )
    if _source_file_status(connection, archive_source_file_id) == "LOADED":
        with zipfile.ZipFile(path) as archive:
            expected_contracts = {
                member.filename: route.parser_contract_version
                for member in archive.infolist()
                if not member.is_dir()
                and (route := _route_for_member(target_name, member.filename)) is not None
            }
        registered_contracts = dict(
            connection.execute(
                """
                select membership.source_member_path, child.parser_contract_version
                from audit.audit_source_file_container as membership
                inner join audit.audit_source_file as child
                    on membership.child_source_file_id = child.source_file_id
                where membership.parent_source_file_id = ?
                  and child.ingestion_status = 'LOADED'
                """,
                [archive_source_file_id],
            ).fetchall()
        )
        if registered_contracts != expected_contracts:
            raise RuntimeError(
                "Archive member set or parser contract drift requires migration: "
                f"registered={registered_contracts}, expected={expected_contracts}"
            )
        LOGGER.info("Skipping already-loaded archive %s", path.name)
        return {"loaded": 0, "skipped": 1}

    run_temp = settings.temp_directory / str(pipeline_run_id)
    run_temp.mkdir(parents=True, exist_ok=True)
    loaded = 0
    skipped = 0
    rows = 0
    with zipfile.ZipFile(path) as archive:
        members = [
            member
            for member in archive.infolist()
            if not member.is_dir() and _route_for_member(target_name, member.filename)
        ]
        if not members:
            raise RuntimeError(f"No supported data members found in {path}")
        for member in sorted(members, key=lambda item: item.filename):
            route = _route_for_member(target_name, member.filename)
            if route is None:
                continue
            existing = _find_source_file(
                connection, dataset_release_id, member.filename, archive_source_file_id
            )
            crc32 = f"{member.CRC:08x}"
            if (
                existing
                and existing[2] == member.file_size
                and existing[3] == crc32
                and existing[4] == route.parser_contract_version
                and existing[5] == "LOADED"
            ):
                LOGGER.info("Skipping loaded archive member %s", member.filename)
                skipped += 1
                continue

            _ensure_free_space(
                settings.database_path.parent, member.file_size, settings.min_free_gib
            )
            temporary_path = run_temp / Path(member.filename).name
            LOGGER.info("Extracting %s (%.2f GiB)", member.filename, member.file_size / GIB)
            source_file_id: uuid.UUID | None = None
            try:
                member_sha256 = _extract_member(archive, member, temporary_path)
                source_file_id = _register_source_file(
                    connection,
                    dataset_release_id=dataset_release_id,
                    pipeline_run_id=pipeline_run_id,
                    parent_source_file_id=archive_source_file_id,
                    file_kind="ZIP_MEMBER_CSV",
                    file_name=member.filename,
                    source_path=f"{path}::{member.filename}",
                    content_sha256=member_sha256,
                    byte_size=member.file_size,
                    parser_contract_version=route.parser_contract_version,
                    zip_crc32=crc32,
                    zip_compressed_size=member.compress_size,
                )
                if _source_file_status(connection, source_file_id) == "LOADED":
                    LOGGER.info("Reusing loaded archive-member content %s", member.filename)
                    skipped += 1
                    continue
                source_columns = _read_header(temporary_path)
                LOGGER.info("Loading %s into bronze.%s", member.filename, route.raw_table)
                member_rows = _load_csv(
                    connection,
                    path=temporary_path,
                    source_columns=source_columns,
                    route=route,
                    dataset_release_id=dataset_release_id,
                    source_file_id=source_file_id,
                    parent_source_file_id=archive_source_file_id,
                    source_member_path=member.filename,
                    content_sha256=member_sha256,
                    pipeline_run_id=pipeline_run_id,
                )
                loaded += 1
                rows += member_rows
                LOGGER.info("Loaded %s rows from %s", f"{member_rows:,}", member.filename)
                connection.execute("checkpoint")
            except Exception as error:
                if source_file_id is not None:
                    _mark_source_file_failed(connection, source_file_id, error)
                message = (str(error) or type(error).__name__)[:4000]
                connection.execute(
                    """
                    update audit.audit_source_file
                    set ingestion_status = 'PARTIAL', failure_message = ?
                    where source_file_id = ?
                    """,
                    [message, archive_source_file_id],
                )
                connection.execute(
                    """
                    update audit.audit_dataset_release
                    set status = 'PARTIAL', loaded_at = null
                    where dataset_release_id = ?
                    """,
                    [dataset_release_id],
                )
                raise
            finally:
                temporary_path.unlink(missing_ok=True)
    run_temp.rmdir()
    _finalize_archive_manifest(connection, archive_source_file_id, dataset_release_id)
    return {"loaded": loaded, "skipped": skipped, "rows": rows}


def run_import(
    *,
    config_path: Path,
    targets: tuple[str, ...],
    database_path: Path | None = None,
    data_root: Path | None = None,
) -> uuid.UUID:
    unsupported = set(targets) - set(ROUTES)
    if unsupported:
        raise ValueError(f"Unsupported import targets: {sorted(unsupported)}")
    settings = load_settings(config_path, database_path=database_path, data_root=data_root)
    connection = _connect(settings)
    pipeline_run_id: uuid.UUID | None = None
    try:
        _create_control_tables(connection)
        pipeline_run_id = _register_pipeline_run(connection, settings, targets)
        summary: dict[str, dict[str, int]] = {}
        for target_name in targets:
            LOGGER.info("Starting target %s", target_name)
            source = settings.sources[target_name]
            if all(route.member_pattern is None for route in ROUTES[target_name]):
                summary[target_name] = _import_direct_file(
                    connection, settings, target_name, source, pipeline_run_id
                )
            else:
                summary[target_name] = _import_archive(
                    connection, settings, target_name, source, pipeline_run_id
                )
        connection.execute(
            """
            update audit.audit_pipeline_run
            set completed_at = ?, run_status = 'SUCCEEDED', target_summary = ?
            where pipeline_run_id = ?
            """,
            [_now(), json.dumps(summary), pipeline_run_id],
        )
        LOGGER.info("Import run %s succeeded: %s", pipeline_run_id, summary)
        return pipeline_run_id
    except Exception as error:
        if pipeline_run_id:
            connection.execute(
                """
                update audit.audit_pipeline_run
                set completed_at = ?, run_status = 'FAILED', failure_message = ?
                where pipeline_run_id = ?
                """,
                [_now(), str(error)[:4000], pipeline_run_id],
            )
        raise
    finally:
        connection.close()


def import_status(database_path: Path) -> list[tuple[Any, ...]]:
    if not database_path.exists():
        return []
    connection = duckdb.connect(str(database_path), read_only=True)
    try:
        return connection.execute(
            """
            select pipeline_run_id, started_at, completed_at, run_status,
                   target_summary, failure_message
            from audit.audit_pipeline_run
            order by started_at desc
            """
        ).fetchall()
    finally:
        connection.close()


def publish_silver_reconciliation(database_path: Path) -> int:
    """Publish tested Silver accepted/quarantined counts to source manifests."""
    connection = duckdb.connect(str(database_path))
    try:
        failure_count = connection.execute(
            """
            select count(*)
            from audit.audit_source_file_silver_reconciliation
            where reconciliation_status <> 'PASSED'
            """
        ).fetchone()[0]
        if failure_count:
            raise RuntimeError(
                f"Cannot publish Silver reconciliation: {failure_count} file(s) failed"
            )

        expected_leaf_count = connection.execute(
            """
            select count(*)
            from audit.audit_source_file
            where file_kind in ('CSV', 'ZIP_MEMBER_CSV')
              and ingestion_status = 'LOADED'
            """
        ).fetchone()[0]
        leaf_count, distinct_leaf_count = connection.execute(
            """
            select count(*), count(distinct source_file_id)
            from audit.audit_source_file_silver_reconciliation
            """
        ).fetchone()
        if leaf_count != expected_leaf_count or distinct_leaf_count != expected_leaf_count:
            raise RuntimeError(
                "Cannot publish Silver reconciliation: expected "
                f"{expected_leaf_count} loaded source files, found {leaf_count} rows "
                f"for {distinct_leaf_count} distinct files"
            )

        stale_count = connection.execute(
            """
            select count(*)
            from audit.audit_source_file_silver_reconciliation as reconciliation
            inner join audit.audit_source_file as manifest
                on reconciliation.source_file_id = manifest.source_file_id
            where reconciliation.reconciled_at < manifest.loaded_at
            """
        ).fetchone()[0]
        if stale_count:
            raise RuntimeError(
                f"Cannot publish Silver reconciliation: {stale_count} file(s) are stale"
            )

        connection.execute("begin transaction")
        try:
            connection.execute(
                """
                update audit.audit_source_file as manifest
                set accepted_row_count = reconciliation.silver_accepted_row_count,
                    quarantined_row_count = reconciliation.silver_quarantined_row_count
                from audit.audit_source_file_silver_reconciliation as reconciliation
                where manifest.source_file_id = reconciliation.source_file_id
                """
            )
            has_container_bridge = connection.execute(
                """
                select count(*) > 0
                from information_schema.tables
                where table_schema = 'audit'
                  and table_name = 'audit_source_file_container'
                """
            ).fetchone()[0]
            if has_container_bridge:
                connection.execute(
                    """
                    update audit.audit_source_file as archive
                    set accepted_row_count = child.accepted_row_count,
                        quarantined_row_count = child.quarantined_row_count
                from (
                    select
                        membership.parent_source_file_id,
                        sum(child.accepted_row_count) as accepted_row_count,
                        sum(child.quarantined_row_count) as quarantined_row_count
                    from audit.audit_source_file_container as membership
                    inner join audit.audit_source_file as child
                        on membership.child_source_file_id = child.source_file_id
                    group by membership.parent_source_file_id
                    ) as child
                    where archive.source_file_id = child.parent_source_file_id
                    """
                )
            else:
                connection.execute(
                    """
                    update audit.audit_source_file as archive
                    set accepted_row_count = child.accepted_row_count,
                        quarantined_row_count = child.quarantined_row_count
                    from (
                        select
                            parent_source_file_id,
                            sum(accepted_row_count) as accepted_row_count,
                            sum(quarantined_row_count) as quarantined_row_count
                        from audit.audit_source_file
                        where parent_source_file_id is not null
                        group by parent_source_file_id
                    ) as child
                    where archive.source_file_id = child.parent_source_file_id
                    """
                )
            connection.execute("commit")
        except Exception:
            connection.execute("rollback")
            raise
        return int(leaf_count)
    finally:
        connection.close()


def default_config_path() -> Path:
    return Path(os.environ.get("EPC_V4_IMPORT_CONFIG", "config/source_import.yml"))
