from __future__ import annotations

import uuid
from datetime import UTC, date, datetime

import duckdb
import pytest

from epc_v5.calibrate_identity import (
    _sample_key,
    evaluate_labels,
    initialize_calibration_tables,
)


def test_calibration_sample_key_changes_with_material_inputs() -> None:
    base = _sample_key("run", "model", 20, "03")

    assert base == _sample_key("run", "model", 20, "03")
    assert base != _sample_key("other-run", "model", 20, "03")
    assert base != _sample_key("run", "other-model", 20, "03")
    assert base != _sample_key("run", "model", 21, "03")


def test_calibration_evaluation_requires_explicit_labels() -> None:
    connection = duckdb.connect()
    initialize_calibration_tables(connection)

    with pytest.raises(RuntimeError, match="requires at least 100"):
        evaluate_labels(connection, minimum_labels=100)


def _insert_with_defaults(
    connection: duckdb.DuckDBPyConnection,
    table: str,
    overrides: dict[str, object],
) -> None:
    columns = connection.execute(f"pragma table_info('{table}')").fetchall()
    values: list[object] = []
    names: list[str] = []
    for _, name, data_type, *_ in columns:
        names.append(name)
        if name in overrides:
            values.append(overrides[name])
        elif data_type == "UUID":
            values.append(uuid.uuid4())
        elif data_type == "DATE":
            values.append(date(2025, 1, 1))
        elif data_type == "TIMESTAMP WITH TIME ZONE":
            values.append(datetime.now(UTC))
        elif data_type in {"DOUBLE", "FLOAT"}:
            values.append(1.0)
        elif "INT" in data_type:
            values.append(1)
        else:
            values.append("fixture")
    placeholders = ", ".join("?" for _ in names)
    connection.execute(
        f"insert into {table} ({', '.join(names)}) values ({placeholders})",
        values,
    )


def test_calibration_evaluation_persists_threshold_metrics() -> None:
    connection = duckdb.connect()
    initialize_calibration_tables(connection)
    connection.execute(
        "create table identity.identity_splink_run (splink_run_id uuid, model_sha256 varchar)"
    )
    sample_id = uuid.uuid4()
    splink_run_id = uuid.uuid4()
    connection.execute(
        "insert into identity.identity_splink_run values (?, 'model-sha')",
        [splink_run_id],
    )

    for index, (label, weight) in enumerate((("MATCH", 20.0), ("NO_MATCH", -5.0))):
        sample_row_key = f"sample-{index}"
        _insert_with_defaults(
            connection,
            "identity.identity_calibration_sample",
            {
                "calibration_sample_row_key": sample_row_key,
                "calibration_sample_id": sample_id,
                "candidate_pair_key": f"pair-{index}",
                "identity_run_key": "run-key",
                "splink_run_id": splink_run_id,
                "match_weight": weight,
            },
        )
        _insert_with_defaults(
            connection,
            "identity.identity_adjudication_label",
            {
                "calibration_sample_row_key": sample_row_key,
                "calibration_sample_id": sample_id,
                "candidate_pair_key": f"pair-{index}",
                "identity_run_key": "run-key",
                "adjudication_label": label,
                "target_scope": "SAME_PREMISES" if label == "MATCH" else "DIFFERENT",
                "label_status": "ACTIVE",
            },
        )

    evaluation_id = evaluate_labels(connection, minimum_labels=2)

    assert (
        connection.execute(
            """
        select count(*) from identity.identity_calibration_evaluation
        where calibration_evaluation_id = ?
        """,
            [evaluation_id],
        ).fetchone()[0]
        == 61
    )
