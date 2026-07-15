# EPC v4

Evidence-first UK property intelligence built with DuckDB, dbt and Splink, with curated Neo4j graph exports.

## Design principle

> Source records remain evidence. Entity links are versioned assertions. Current state is derived for an as-of date. Policy outputs are cautious, versioned screening results.

The authoritative design is [`docs/epc-v4-data-model-design.md`](docs/epc-v4-data-model-design.md).

## Quick start

```bash
make setup
source .venv/bin/activate
dbt debug --profiles-dir .
dbt parse --profiles-dir .
pytest
```

## Project structure

```text
models/audit         run, file and release control
models/bronze        immutable source-shaped evidence
models/silver        typed source observations
models/identity      Splink evidence, decisions and persistent registry
models/intermediate  reusable private transformations
models/core          buildings, dwellings, facts and assertion bridges
models/mart          current EPC, MEES and retrofit products
models/graph_export  scoped, referentially closed Neo4j projections
```

## Important boundaries

- Do not copy v3 model logic without checking it against the v4 design.
- Do not use `ROW_NUMBER()` for durable identifiers.
- Do not call a Splink cluster a confirmed property.
- Do not infer current tenancy from EPC tenure.
- Do not describe MEES screening as legal advice or definitive compliance.
- Do not treat PPD Category B as proof of investment ownership.
- Do not publish address-level graph exports without current licensing and privacy review.

No source data or generated databases are committed to Git.
