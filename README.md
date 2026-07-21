# EPC v5

EPC v5 is a vector-free property identity pipeline for HM Land Registry Price Paid
Data, domestic EPC records, and ONS geography data. DuckDB is authoritative, dbt
owns transformation contracts, Splink 4 supplies probabilistic comparison evidence,
and libpostal is used selectively for difficult flat and unit addresses.

The governing principle is:

> Source records remain evidence. Entity links are versioned assertions. Current state
> is derived for an explicit as-of date. Policy outputs are cautious, versioned screens.

The authoritative model specification is
[`docs/epc-v5-data-model-design.md`](docs/epc-v5-data-model-design.md). The executable
clean-build and restart procedures are in
[`docs/epc-v5-rebuild-guide.md`](docs/epc-v5-rebuild-guide.md).

## Implemented Scope

- Audited Bronze ingestion for PPD, EPC, ONSUD, LAD, and LPA source files.
- Typed Silver observations, quarantine evidence, and source-file reconciliation.
- Selective libpostal parsing for the EPC flat-trap route.
- Deterministic identity observations and D01/P01/P02/P04 candidate generation.
- Splink benchmark training and immutable national score publication.
- Review-only decisions, alternatives, hypotheses, singleton outcomes, and assignments.
- Atomic sale, EPC certificate, recommendation, coordinate, and geography core models.
- Deterministic calibration sampling with manual-only label import and evaluation.

## Future Scope

- `models/mart/` does not yet contain implemented current-EPC, MEES, or retrofit marts.
- `models/graph_export/` does not yet contain implemented Neo4j export contracts.
- Persistent registry promotion remains disabled while the decision policy is uncalibrated.

No vector embeddings, FastEmbed, ONNX Runtime, MiniLM/MPNet models, semantic blocking,
or address-vector tables are part of EPC v5.

## Quick Start

```bash
make setup
make debug
make test
make lint
```

For a new database use `bin/run_pipeline.sh clean-build`. For the existing database use
`bin/run_pipeline.sh resume`; it verifies completed immutable stages instead of rerunning
them.

## Project Structure

```text
models/audit         ingestion controls, quarantine, reconciliation
models/silver        typed source observations and address routing
models/identity      candidates, scores, decisions, hypotheses, assignments
models/intermediate  reusable source-to-core bridges
models/core          atomic facts, coordinates, geography, registry foundations
models/mart          future dated-state and policy products
models/graph_export  future referentially closed graph projections
```

## Important Boundaries

- Do not copy EPC v3 logic without checking it against the v5 design.
- Do not use row numbers for durable identifiers.
- Do not call a Splink score, candidate, or cluster a confirmed property.
- Do not promote registry entities under the uncalibrated policy.
- Do not infer labels, current tenancy, legal compliance, or investment intent.
- Do not add vector or semantic dependencies.
- Do not commit source data, generated databases, logs, or calibration exports.
