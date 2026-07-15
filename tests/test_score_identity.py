from __future__ import annotations

from epc_v4.score_identity import D01_SQL, P01_SQL, P02_SQL, create_settings


def test_identity_splink_settings_pin_expected_rules_and_model_status() -> None:
    settings = create_settings(salting_partitions=4, linker_uid="fixture")
    settings_dict = settings.get_settings("duckdb").as_dict()

    rules = settings_dict["blocking_rules_to_generate_predictions"]
    assert [rule["blocking_rule"] for rule in rules] == [D01_SQL, P01_SQL, P02_SQL]
    assert settings_dict["probability_two_random_records_match"] == 0.000001
    assert settings_dict["retain_intermediate_calculation_columns"] is True
    assert settings_dict["unique_id_column_name"] == "unique_id"
