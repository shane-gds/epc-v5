from __future__ import annotations

import pandas as pd
import pytest

from epc_v4.address_components import (
    canonical_role_component,
    combine_parsed_components,
    complete_number_designator,
    first_number_token,
    normalise_component,
    number_designator,
)
from epc_v4.benchmark_libpostal import (
    create_immutable_output_directory,
    evaluate_parsed_row,
    summarise_results,
)
from epc_v4.libpostal_runtime import fingerprint_directory


def test_component_normalisation_preserves_alphanumeric_numbers() -> None:
    assert normalise_component("  Flat 5A, ") == "FLAT 5A"
    assert first_number_token("Flat 5A") == "5A"
    assert first_number_token("11-13") == "11"
    assert first_number_token("The Convent") is None
    assert canonical_role_component("11-13") == "11-13"
    assert canonical_role_component("Flat 5A", unit=True) == "5A"
    assert number_designator("BRIGHTHAMPTON, 55 - 57") == "55-57"
    assert complete_number_designator("BRIGHTHAMPTON, 55 - 57") == "55-57"
    assert complete_number_designator("11/13") is None
    assert complete_number_designator("11 AND 13") is None
    assert complete_number_designator("11AB") is None
    assert complete_number_designator("A11") is None
    assert complete_number_designator("11/ABC") is None


def test_combining_repeated_parser_labels_is_deterministic() -> None:
    assert combine_parsed_components(
        [("flat 5", "unit"), ("11", "house_number"), ("high st", "road")]
    ) == {"unit": "flat 5", "house_number": "11", "road": "high st"}


def test_evaluate_parsed_row_scores_roles_separately() -> None:
    def fake_parser(_: str) -> list[tuple[str, str]]:
        return [("flat 5", "unit"), ("11", "house_number"), ("high street", "road")]

    result = evaluate_parsed_row("ignored", "11", "5", "High Street", fake_parser)

    assert result["house_number_matches_expected"] is True
    assert result["paon_full_matches_expected"] is True
    assert result["unit_matches_expected"] is True
    assert result["road_matches_expected"] is True
    assert result["road_compatible_with_expected"] is True
    assert result["number_roles_recovered"] is True
    assert result["compatible_candidate_recovered"] is True
    assert result["strict_candidate_recovered"] is True
    assert result["role_swap"] is False


def test_evaluate_parsed_row_detects_role_swap() -> None:
    def swapped_parser(_: str) -> list[tuple[str, str]]:
        return [("unit 11", "unit"), ("5", "house_number"), ("high street", "road")]

    result = evaluate_parsed_row("ignored", "11", "5", "High Street", swapped_parser)

    assert result["strict_candidate_recovered"] is False
    assert result["role_swap"] is True


def test_evaluate_parsed_row_requires_full_range_and_safe_road_direction() -> None:
    def range_parser(_: str) -> list[tuple[str, str]]:
        return [("flat 5", "unit"), ("11-13", "house_number"), ("maida", "road")]

    result = evaluate_parsed_row("ignored", "11-13", "5", "Maida Vale", range_parser)

    assert result["house_number_matches_expected"] is True
    assert result["road_compatible_with_expected"] is False
    assert result["compatible_candidate_recovered"] is False


def test_evaluate_parsed_row_never_matches_two_rejected_designators() -> None:
    def unsupported_parser(_: str) -> list[tuple[str, str]]:
        return [("flat 5", "unit"), ("11/13", "house_number"), ("high street", "road")]

    result = evaluate_parsed_row("ignored", "11/15", "5", "High Street", unsupported_parser)

    assert result["house_number_matches_expected"] is False
    assert result["number_roles_recovered"] is False
    assert result["strict_candidate_recovered"] is False


def test_directory_fingerprint_frames_paths_and_contents(tmp_path) -> None:
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()
    (first / "a").write_text("bc", encoding="utf-8")
    (second / "ab").write_text("c", encoding="utf-8")

    assert fingerprint_directory(first)[0] != fingerprint_directory(second)[0]


def test_immutable_output_directory_rejects_overwrite(tmp_path) -> None:
    created = create_immutable_output_directory(tmp_path, "benchmark-key")

    assert created.is_dir()
    with pytest.raises(FileExistsError):
        create_immutable_output_directory(tmp_path, "benchmark-key")


def test_summary_reports_component_and_recovery_rates() -> None:
    frame = pd.DataFrame(
        [
            {
                "house_number_present": True,
                "unit_present": True,
                "road_present": True,
                "house_number_matches_expected": True,
                "paon_full_matches_expected": True,
                "unit_matches_expected": True,
                "road_matches_expected": True,
                "road_compatible_with_expected": True,
                "role_swap": False,
                "number_roles_recovered": True,
                "compatible_candidate_recovered": True,
                "strict_candidate_recovered": True,
                "parse_error": None,
            },
            {
                "house_number_present": True,
                "unit_present": False,
                "road_present": True,
                "house_number_matches_expected": False,
                "paon_full_matches_expected": False,
                "unit_matches_expected": False,
                "road_matches_expected": True,
                "road_compatible_with_expected": True,
                "role_swap": False,
                "number_roles_recovered": False,
                "compatible_candidate_recovered": False,
                "strict_candidate_recovered": False,
                "parse_error": "ValueError: fixture",
            },
        ]
    )

    summary = summarise_results(frame, elapsed_seconds=2.0)

    assert summary["row_count"] == 2
    assert summary["rows_per_second"] == 1.0
    assert summary["house_number_present_rate"] == 1.0
    assert summary["unit_present_rate"] == 0.5
    assert summary["number_roles_recovered_rate"] == 0.5
    assert summary["compatible_candidate_recovered_rate"] == 0.5
    assert summary["strict_candidate_recovered_rate"] == 0.5
    assert summary["parse_error_count"] == 1
