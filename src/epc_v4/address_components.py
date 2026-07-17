"""Versioned address-component normalization shared by parser consumers."""

from __future__ import annotations

import json
import math
import re
from collections import defaultdict
from collections.abc import Callable
from numbers import Real
from typing import Any

NON_ALNUM = re.compile(r"[^A-Z0-9]+")
NUMBER_TOKEN = re.compile(r"(?<![A-Z0-9])([0-9]+[A-Z]?)(?![A-Z0-9])")
NUMBER_DESIGNATOR = re.compile(
    r"(?<![A-Z0-9])([0-9]+[A-Z]?(?:[ ]*-[ ]*[0-9]+[A-Z]?)?)(?![A-Z0-9])"
)
UNIT_PREFIX = re.compile(r"^(FLAT|APARTMENT|APT|UNIT|ROOM|MAISONETTE)[ ]*")


def _is_missing(value: Any) -> bool:
    return value is None or (isinstance(value, Real) and math.isnan(value))


def normalise_component(value: Any) -> str | None:
    """Normalize a parser component without changing its semantic role."""
    if _is_missing(value):
        return None
    normalised = NON_ALNUM.sub(" ", str(value).upper()).strip()
    return normalised or None


def first_number_token(value: Any) -> str | None:
    """Return the first standalone number token for benchmark compatibility."""
    normalised = normalise_component(value)
    if normalised is None:
        return None
    match = NUMBER_TOKEN.search(normalised)
    return match.group(1) if match else None


def canonical_role_component(value: Any, *, unit: bool = False) -> str | None:
    """Canonicalize a unit or building designator while preserving ranges."""
    if _is_missing(value):
        return None
    normalised = str(value).upper().strip()
    if unit:
        normalised = UNIT_PREFIX.sub("", normalised)
    canonical = re.sub(r"[^A-Z0-9/-]+", "", normalised)
    return canonical or None


def number_designator(value: Any) -> str | None:
    """Extract a complete numeric or alphanumeric building-number designator."""
    if _is_missing(value):
        return None
    match = NUMBER_DESIGNATOR.search(str(value).upper())
    return re.sub(r"[ ]+", "", match.group(1)) if match else None


def complete_number_designator(value: Any) -> str | None:
    """Extract one final designator; reject compound, adjacent, or residual forms."""
    if _is_missing(value):
        return None
    text = str(value).upper().strip()
    if "/" in text:
        return None
    matches = list(NUMBER_DESIGNATOR.finditer(text))
    if len(matches) != 1:
        return None
    match = matches[0]
    if text[match.end() :].strip(" ,."):
        return None
    return re.sub(r"[ ]+", "", match.group(1))


def combine_parsed_components(parsed: list[tuple[str, str]]) -> dict[str, str]:
    """Group repeated libpostal labels deterministically without reordering them."""
    grouped: dict[str, list[str]] = defaultdict(list)
    for component, label in parsed:
        grouped[str(label)].append(str(component))
    return {label: " ".join(values) for label, values in grouped.items()}


def parse_address_components(
    parser_input: str,
    parse_address: Callable[[str], list[tuple[str, str]]],
) -> dict[str, Any]:
    """Parse one address and retain both ordered raw and canonical components."""
    ordered = [
        {"ordinal": ordinal, "value": str(value), "label": str(label)}
        for ordinal, (value, label) in enumerate(parse_address(parser_input), start=1)
    ]
    grouped = combine_parsed_components(
        [(component["value"], component["label"]) for component in ordered]
    )
    parsed_house = grouped.get("house")
    parsed_house_number = grouped.get("house_number")
    parsed_unit = grouped.get("unit")
    parsed_road = grouped.get("road")
    house_number_designator = complete_number_designator(parsed_house_number)
    unit_comparison = canonical_role_component(parsed_unit, unit=True)
    road_comparison = normalise_component(parsed_road)
    status = (
        "COMPLETE"
        if house_number_designator and unit_comparison and road_comparison
        else "INCOMPLETE"
    )
    return {
        "ordered_components_json": json.dumps(ordered, ensure_ascii=False),
        "grouped_components_json": json.dumps(grouped, sort_keys=True, ensure_ascii=False),
        "parsed_house": parsed_house,
        "parsed_house_number": parsed_house_number,
        "parsed_unit": parsed_unit,
        "parsed_road": parsed_road,
        "building_number_designator": house_number_designator,
        "unit_identifier_comparison": unit_comparison,
        "road_comparison": road_comparison,
        "parse_status": status,
    }
