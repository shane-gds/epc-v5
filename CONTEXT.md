# EPC v4 project handoff

**Handoff date:** 14 July 2026
**Previous workspace:** `/home/shamus/dev/epc-v3`
**Current project:** `/home/shamus/dev/epc-v5`

## Mission

Build EPC v4 as a greenfield, evidence-first UK property intelligence pipeline using DuckDB, dbt and Splink, with Neo4j receiving only curated, scoped graph projections.

The guiding principle is:

> Source records remain evidence. Entity links are versioned assertions. Current state is derived for an explicit as-of date. Policy outputs are cautious, versioned screening results.

## Authoritative documents

Read these before implementing models:

1. `AGENTS.md` — non-negotiable implementation principles.
2. `docs/epc-v5-data-model-design.md` — authoritative model-by-model specification, narrative, ER diagrams, columns, tests and implementation phases.
3. `README.md` — project structure and quick start.

The v4 design document was developed from lessons learned in epc-v3, but v3 model code is **not** the implementation specification.

## Settled design decisions

- DuckDB/dbt is authoritative; Neo4j is a curated projection.
- Layers: Audit, Bronze, Silver, Identity, Intermediate, Core, Mart and Graph Export.
- Buildings, dwellings and unresolved premises candidates are distinct grains.
- Every eligible source record receives an assignment outcome; Splink singletons never disappear.
- Splink candidate pairs, scores, decisions, hypotheses and assignments are separate models.
- Immutable source/event/relationship keys use namespaced SHA-256 macros.
- Evolving premises/building/dwelling entities use persistent registry UUIDs.
- Current EPC is derived for an explicit `as_of_date` with deterministic chronology.
- MEES output is cautious, policy-versioned screening—not legal compliance advice.
- EPC tenure is assessment-time evidence, not proof of current tenancy.
- PPD Category B is an additional transaction category, not investment proof.
- Recommendation observations remain source evidence; canonical Measure concepts are versioned mappings.
- ONSUD is release-aware. Approximate postcode/sector coordinates cannot assign exact LSOA/MSOA/LAD.
- `ST_Transform` is performed once per distinct required coordinate pair in a narrow model.
- Splink scratch tables live in a separate run-specific DuckDB file.
- Graph exports use scoped dbt marts, stable IDs, endpoint closure, disclosure profiles and DuckDB `COPY`.

## Current scaffold state

Created:

- `pyproject.toml` with DuckDB, dbt, Splink and optional dev/graph/Parquet dependencies.
- `dbt_project.yml`, `profiles.yml`, `packages.yml`.
- Layered `models/` directories.
- `macros/generate_schema_name.sql`.
- `macros/stable_sha256.sql`.
- Python package under `src/epc_v5/`.
- `README.md`, `AGENTS.md`, `.gitignore`, `.env.example`, `Makefile`.
- Full v4 design document under `docs/`.

Not yet completed:

1. Create `.venv` and install dependencies.
2. Run `dbt deps`.
3. Run `dbt debug --profiles-dir .`.
4. Run `dbt parse --profiles-dir .`.
5. Add a smoke fixture/model to compile and test the SHA-256 macro.
6. Run pytest, Ruff and SQLFluff smoke checks.
7. Initialise Git and inspect status.
8. Do not commit until explicitly requested.

## Proven dependency baseline from epc-v3

```text
Python 3.12
duckdb 1.5.4
dbt-core 1.11.12
dbt-duckdb 1.10.1
splink 4.0.16
pandas 3.0.3
```

The v4 `pyproject.toml` pins these proven core versions and defines optional dependency groups for development, Neo4j and Parquet.

## Immediate next command

From the v4 project root:

```bash
make setup
```

Then verify:

```bash
.venv/bin/python -m epc_v5
.venv/bin/dbt debug --profiles-dir .
.venv/bin/dbt parse --profiles-dir .
.venv/bin/python -m pytest
```

## First implementation phase

Begin with the control and evidence foundation rather than property matching:

```text
audit_dataset_release
    -> audit_source_file
        -> raw source tables
            -> typed Silver observation models
```

Do not begin Splink implementation until source release, file, source-row, business-key and reconciliation contracts are working.

## Instructions for a new Kilo session

Start the new session with:

> Read `AGENTS.md`, `CONTEXT.md`, `README.md`, and the relevant sections of `docs/epc-v5-data-model-design.md`. Continue from the handoff. First verify the scaffold and dependency installation status; do not copy v3 models or data.

The full design document is large. Read its overview and the specific model chapter relevant to the current task rather than loading all 3,000+ lines unless a whole-architecture review is needed.
