"""Namespaced SHA-256 keys shared by ingestion and dbt fixtures."""

from __future__ import annotations

import hashlib
from collections.abc import Iterable


def _component(value: object | None) -> str:
    if value is None:
        return "N;"
    text = str(value)
    return f"V{len(text.encode('utf-8')):020d}:{text};"


def stable_sha256(
    key_namespace: str,
    payload_version: str,
    fields: Iterable[object | None],
) -> str:
    """Return the lowercase SHA-256 key defined by the v4 SK1 contract."""
    payload = [
        "SK1;",
        f"NS={_component(key_namespace)}",
        f"PV={_component(payload_version)}",
    ]
    payload.extend(
        f"P{position:020d}={_component(value)}" for position, value in enumerate(fields, start=1)
    )
    return hashlib.sha256("".join(payload).encode("utf-8")).hexdigest()


def sql_literal(value: str) -> str:
    """Quote a trusted string value as a DuckDB SQL literal."""
    return "'" + value.replace("'", "''") + "'"


def stable_sha256_sql(
    key_namespace: str,
    payload_version: str,
    fields: Iterable[str],
) -> str:
    """Build a DuckDB expression equivalent to :func:`stable_sha256`."""

    def component(expression: str) -> str:
        return (
            "case when "
            f"{expression} is null then 'N;' else concat('V', "
            "lpad(cast(octet_length(encode(cast("
            f"{expression} as varchar))) as varchar), 20, '0'), ':', "
            f"cast({expression} as varchar), ';') end"
        )

    parts = [
        "'SK1;'",
        f"'NS=', {component(sql_literal(key_namespace))}",
        f"'PV=', {component(sql_literal(payload_version))}",
    ]
    for position, field in enumerate(fields, start=1):
        parts.append(f"'P', lpad('{position}', 20, '0'), '=', {component(field)}")
    return f"sha256(concat({', '.join(parts)}))"
