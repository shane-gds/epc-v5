from __future__ import annotations

import duckdb

from epc_v4.stable_keys import sql_literal, stable_sha256, stable_sha256_sql


def test_python_and_duckdb_stable_keys_match() -> None:
    fields = [None, "", "a|b", "Merton Lane", "001"]
    expected = stable_sha256("epc-v4.test", "v1", fields)
    expressions = ["null"] + [sql_literal(value) for value in fields[1:]]

    actual = (
        duckdb.connect()
        .execute(f"select {stable_sha256_sql('epc-v4.test', 'v1', expressions)}")
        .fetchone()[0]
    )

    assert actual == expected


def test_stable_key_distinguishes_null_empty_position_and_namespace() -> None:
    base = stable_sha256("epc-v4.test", "v1", [None, ""])

    assert base != stable_sha256("epc-v4.test", "v1", ["", None])
    assert base != stable_sha256("epc-v4.other", "v1", [None, ""])
    assert base != stable_sha256("epc-v4.test", "v2", [None, ""])
