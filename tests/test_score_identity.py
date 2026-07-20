from __future__ import annotations

import duckdb

from epc_v5.score_identity import D01_SQL, P01_SQL, P02_SQL, P04_SQL, create_settings


def test_identity_splink_settings_pin_expected_rules_and_model_status() -> None:
    settings = create_settings(salting_partitions=4, linker_uid="fixture")
    settings_dict = settings.get_settings("duckdb").as_dict()

    rules = settings_dict["blocking_rules_to_generate_predictions"]
    assert [rule["blocking_rule"] for rule in rules] == [
        D01_SQL,
        P01_SQL,
        P02_SQL,
        P04_SQL,
    ]
    assert settings_dict["probability_two_random_records_match"] == 0.000001
    assert settings_dict["retain_intermediate_calculation_columns"] is True
    assert settings_dict["unique_id_column_name"] == "unique_id"


def _p04_matches(*, pp_road: str, epc_road: str, unit: str = "5") -> bool:
    connection = duckdb.connect()
    count = connection.execute(
        f"""
        select count(*)
        from (
            select
                'PPD' as source_dataset,
                'S1 1AA' as postcode,
                ? as unit_identifier_comparison,
                '11' as building_number_designator,
                '11 HIGH STREET FLAT 5' as premise_address_comparison,
                ? as road_comparison,
                'PPD_STRUCTURED_FIELDS' as address_component_method,
                'COMPLETE' as address_component_status,
                'ADMITTED' as libpostal_candidate_block_status
        ) as l
        cross join (
            select
                'EPC_CERTIFICATE' as source_dataset,
                'S1 1AA' as postcode,
                '5' as unit_identifier_comparison,
                '11' as building_number_designator,
                'FLAT 5 11 HIGH STREET' as premise_address_comparison,
                ? as road_comparison,
                'LIBPOSTAL' as address_component_method,
                'COMPLETE' as address_component_status,
                'ADMITTED' as libpostal_candidate_block_status
        ) as r
        where {P04_SQL}
        """,
        [unit, pp_road, epc_road],
    ).fetchone()[0]
    connection.close()
    return count == 1


def test_p04_requires_exact_roles_and_safe_directional_road_compatibility() -> None:
    assert _p04_matches(pp_road="HIGH STREET", epc_road="THE BUILDING HIGH STREET")
    assert not _p04_matches(pp_road="MAIDA VALE", epc_road="MAIDA")
    assert not _p04_matches(pp_road="HIGH STREET", epc_road="HIGH STREET", unit="6")
