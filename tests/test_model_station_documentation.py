from __future__ import annotations

from pathlib import Path

import yaml

PROJECT_ROOT = Path(__file__).resolve().parents[1]
MODEL_ROOT = PROJECT_ROOT / "models"
STATION_HEADERS = {
    "[Station 1 (Ingestion & Raw Landing)]",
    "[Station 2 (The Scrubbing Station)]",
    "[Station 3 (Standardization & Token Normalization)]",
    "[Station 4 (Blocking & Candidate Generation)]",
    "[Station 5 (The Detective's Scoring Office)]",
    "[Station 6 (The Executive Decision Room)]",
}


def test_every_dbt_model_has_a_station_first_description() -> None:
    documented_models: dict[str, Path] = {}
    invalid_descriptions: list[str] = []

    for schema_path in sorted(MODEL_ROOT.rglob("*.yml")):
        schema = yaml.safe_load(schema_path.read_text(encoding="utf-8")) or {}
        for model in schema.get("models", []):
            model_name = model["name"]
            documented_models[model_name] = schema_path
            description_lines = str(model.get("description", "")).splitlines()
            first_line = description_lines[0].strip() if description_lines else ""
            if first_line not in STATION_HEADERS:
                invalid_descriptions.append(f"{model_name} ({schema_path})")

    sql_models = {path.stem for path in MODEL_ROOT.rglob("*.sql")}
    assert set(documented_models) == sql_models
    assert invalid_descriptions == []
