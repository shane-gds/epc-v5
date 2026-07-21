# EPC v5 project handoff

**Updated:** 21 July 2026
**Fork point:** EPC v4 commit `5acf23b`, before vector matching was introduced
**Workspace:** `/home/shamus/dev/epc-v5`

## Mission

EPC v5 is a clean, vector-free implementation of an evidence-first UK property identity
pipeline. It links PPD and domestic EPC observations with DuckDB, dbt, Splink 4, and a
selective libpostal route. DuckDB/dbt remains authoritative; any future Neo4j output is a
curated projection only.

## Required Reading

1. `AGENTS.md`
2. `docs/epc-v5-data-model-design.md`
3. `docs/epc-v5-rebuild-guide.md`
4. `docs/epc-v5-implementation-history.md`

## Current Implementation Position

- Source import, Silver staging, selective libpostal parsing, candidates, benchmark
  scoring, national scoring, review-only decisions, hypotheses, assignments, core facts,
  and a deterministic calibration sample have been produced for the current local data.
- National comparison output remains explicitly uncalibrated. Registry promotion is
  correctly empty and must remain disabled pending approved manual calibration.
- `models/mart/` and `models/graph_export/` are future scope.
- No vector embeddings or semantic matching components are present or permitted.

The database and generated evidence are local artifacts and are not committed. Use the
audit tables and `bin/run_pipeline.sh resume` to inspect or continue the current state;
never infer completion from file presence alone.

## Operating Constraints

- Baseline resource profile: one dbt thread, one DuckDB thread, 8GB DuckDB memory, and
  120GB maximum temp spill after a disk-space preflight.
- The VM has approximately 18GB RAM and 15GB swap. Swap and spill reduce OOM risk but do
  not replace RAM.
- Neo4j, when needed, runs in Docker as `neo4j-epc`; stop it with
  `docker stop neo4j-epc` before memory-intensive DuckDB work.
- Do not rerun successful Splink benchmark or national publication stages. The national
  publication is immutable for an identity run and model artifact.
- Calibration labels are manual evidence. Never synthesize or infer them.

## Next User-Governed Step

Manually review the exported calibration CSV, populate permitted label fields, import the
adjudicated file with `make calibration-import LABELS_PATH=/absolute/path.csv`, and run
`make calibration-evaluate`. Registry promotion remains out of scope until a calibrated
decision policy is explicitly approved.
