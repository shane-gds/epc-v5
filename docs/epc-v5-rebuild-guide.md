# EPC v5 Clean Rebuild and Resume Guide

This guide describes two different operations:

- **Clean build:** create a new DuckDB database from the registered source files.
- **Resume:** inspect the existing database, skip completed immutable stages, and build or
  validate only missing stages.

Never point a clean build at an existing database. The authoritative local database is
`output/duckdb/epc_v5.duckdb`; it must not be deleted or reset to test this guide.

EPC v5 is intentionally vector-free. Do not install FastEmbed, ONNX Runtime,
sentence-transformers, MiniLM/MPNet models, or any semantic/vector blocking component.

## 1. Capacity and Resource Policy

The completed current database is approximately 146GiB. A clean build must accommodate
the source files, database growth, and simultaneous DuckDB spill. Reserve at least 300GiB
free disk before starting; 320GiB or more is preferable. Disk space does not substitute
for RAM, although DuckDB spill and operating-system swap reduce OOM risk.

The baseline profile for the 18GB VM is:

```bash
export EPC_V5_DUCKDB_PATH=output/duckdb/epc_v5.duckdb
export EPC_V5_DBT_THREADS=1
export EPC_V5_DUCKDB_THREADS=1
export EPC_V5_MEMORY_LIMIT=8GB
export EPC_V5_MAX_TEMP_SIZE=120GB
export EPC_V5_SPLINK_TEMP_DIR=output/tmp/splink
export EPC_V5_CALIBRATION_TEMP_DIR=output/tmp/calibration
```

The VM currently has approximately 15GB swap. Check resources immediately before a
large model:

```bash
free -h
df -h .
```

If Neo4j is running, stop its Docker container before memory-intensive work:

```bash
docker stop neo4j-epc
```

The recommendation fact can require unusually large spill during a first build or full
refresh. Increase memory or spill only after checking actual free RAM/disk. The current
large dataset required a one-off 16GB memory/140GB spill run while Neo4j was stopped; that
is not the safe default for routine work.

`.env.example` is illustrative and is not loaded automatically. Source it explicitly or
export variables in the shell. Splink and calibration resource settings are CLI options,
so the Make targets pass the same baseline values explicitly.

## 2. Python Environment

`make setup` is the recommended environment bootstrap:

```bash
make setup
source .venv/bin/activate
make debug
```

It creates a Python 3.12 venv with pip, installs the project and development dependencies,
and runs `dbt deps`. If using `uv venv`, use `uv venv --seed` or run `ensurepip` before a
Make target that invokes `.venv/bin/pip`.

## 3. Automated Entry Points

For a genuinely new database:

```bash
bin/run_pipeline.sh clean-build
```

The command refuses to overwrite an existing `EPC_V5_DUCKDB_PATH` and requires at least
300GiB free disk.

The baseline remains intentionally conservative. The current full-size recommendation
fact and target-alternative models have required a one-off larger profile. If a clean build
stops specifically on one of those models after normal spill, stop competing services,
recheck RAM/swap/disk, and resume with an explicit operator-approved override such as:

```bash
EPC_V5_MEMORY_LIMIT=16GB EPC_V5_MAX_TEMP_SIZE=140GB \
  bin/run_pipeline.sh resume
```

Do not make this override the machine-wide default.

For the current database or an interrupted build:

```bash
bin/run_pipeline.sh resume
```

The resume workflow:

1. takes an exclusive pipeline lock;
2. verifies configured source releases, file sizes, SHA-256 content hashes, parser
   contracts, and model relations before rebuilding anything;
3. validates an existing libpostal publication and candidate population;
4. discovers successful benchmarks only for the current identity run/model version;
5. verifies the model file checksum;
6. skips national scoring only after candidate/score/distinct-pair closure;
7. verifies the calibration CSV checksum;
8. runs bounded validation groups;
9. requires all 50 dbt model relations before reporting completion.

If multiple successful benchmark artifacts exist, resume stops and requires an explicit
`MODEL_PATH`. It never silently selects the latest model.

Before benchmark, national scoring, or calibration sampling, resume checks free space on
the filesystem containing the relevant configured temp directory. Required headroom is
the spill limit plus 20GiB. Database storage is checked separately, which matters when
scratch and the authoritative database are on different mounts.

To run unattended:

```bash
tmux new-session -d -s epc-v5 \
  'bin/run_pipeline.sh resume 2>&1 | tee output/epc-v5-resume.log'
tail -f output/epc-v5-resume.log
```

The remaining sections show the exact manual sequence used by the orchestrator.

## 4. Source Import

Source paths and release metadata are registered in `config/source_import.yml`.

```bash
make import
```

Equivalent CLI:

```bash
.venv/bin/python -m epc_v5 import-sources \
  --config config/source_import.yml \
  --database output/duckdb/epc_v5.duckdb
```

The importer is content-idempotent. Loaded files and archive members are skipped on a
retry, but each invocation records a pipeline run. It does not delete source evidence.

Inspect runs with:

```bash
.venv/bin/python -m epc_v5 import-status \
  --config config/source_import.yml \
  --database output/duckdb/epc_v5.duckdb
```

## 5. dbt Dependencies and Seed

```bash
make dbt-deps
make seed
```

The seed contains the governed identity blocking policy. Changing its contents or version
changes identity-run lineage and is not a maintenance operation.

## 6. Silver Models

```bash
make silver
```

This builds only the six source-observation models:

- `stg_epc_certificate_observation`
- `stg_epc_recommendation_observation`
- `stg_pp_transaction_observation`
- `stg_onsud_uprn_allocation`
- `stg_lad_name_code_reference`
- `stg_lpa_name_code_reference`

Do not use `tag:silver` at this point. That tag can select downstream tests whose other
parents do not yet exist.

## 7. Silver Reconciliation and Quarantine

Build the ONSUD source bridge and the three audit relations in dependency order, run their
gates, and publish tested counts back to source manifests:

```bash
make silver-audit
```

Relations:

1. `intermediate.bridge_onsud_allocation_source_record`
2. `audit.quarantine_source_record`
3. `audit.audit_silver_quality_profile`
4. `audit.audit_source_file_silver_reconciliation`

The publication command refuses incomplete, failed, duplicated, or stale source-file
coverage. For validation without rebuilding:

```bash
make silver-audit-tests
```

## 8. Libpostal Setup and Selective Parse

Build or verify the pinned native runtime once:

```bash
make libpostal-setup
```

Then build the route and parse only selected EPC flat/unit traps:

```bash
make libpostal-parse
```

Do not call `make libpostal-parse` immediately before another target that also invokes it.
The current `identity-candidates` target deliberately has no libpostal prerequisite; the
orchestrator checks for a successful current publication first.

## 9. Identity Candidates

```bash
make identity-candidates
```

This seeds the blocking policy, builds current-run observations and D01/P01/P02/P04 rule
hits/pairs, and runs the bounded candidate gates. It preserves deterministic incremental
records on interruption. Validate without rebuilding using:

```bash
make identity-candidate-tests
```

## 10. Splink Benchmark

```bash
make splink-benchmark
```

Defaults are one thread, 8GB memory, two salting partitions, one million random u-pairs,
and `--sample-hex-max 03`. Splink requires more than one salting partition. Prefixes `00`
through `03` are admitted, approximately 1/64 per deterministic block-signature branch;
this is not a simple 1/256 row sample.

Every benchmark invocation creates a new run row, model artifact, and benchmark scores.
Do not rerun it merely to test automation.

## 11. Select the Benchmark Artifact

List successful benchmark artifacts for the current identity run and comparison version:

```bash
make splink-models
```

Equivalent governance query:

```sql
select
    benchmark.splink_run_id,
    benchmark.model_path,
    benchmark.model_sha256,
    benchmark.settings_json,
    benchmark.training_sample_predicate,
    benchmark.completed_at
from identity.identity_splink_run as benchmark
inner join identity.int_identity_current_run as current_run
    on benchmark.identity_run_key = current_run.identity_run_key
    and benchmark.model_version = current_run.comparison_model_version
where
    benchmark.run_mode = 'BENCHMARK'
    and benchmark.run_status = 'SUCCEEDED'
order by benchmark.completed_at desc;
```

If more than one row exists, an operator must approve one exact path and hash. Verify the
file before national scoring:

```bash
MODEL_PATH='output/identity/<identity-run-key>/<benchmark-run-id>/splink_model.json'
sha256sum "$MODEL_PATH"
```

The currently published model is immutable and contains the historical `epcv4_` linker
UID generated before the naming correction. Preserve it. New benchmark artifacts use an
`epcv5_` linker UID; that cosmetic correction does not rewrite existing evidence.

## 12. National Splink Scoring

`MODEL_PATH` is mandatory:

```bash
make splink-national MODEL_PATH="$MODEL_PATH"
```

Equivalent CLI:

```bash
.venv/bin/python -m epc_v5.score_identity \
  --mode national \
  --database output/duckdb/epc_v5.duckdb \
  --model-path "$MODEL_PATH" \
  --threads 1 \
  --memory-limit 8GB \
  --temp-directory output/tmp/splink \
  --max-temp-size 120GB
```

National publication is immutable. A successful publication must reconcile candidate
count, score count, and distinct scored pair count. Do not rerun a completed publication.
If scores exist without a publication, stop for manual recovery rather than deleting or
appending data.

## 13. Downstream Identity Models

```bash
make identity-downstream
```

This builds current scores, review-only decisions, observation and target alternatives,
hypotheses, singleton outcomes, assignments, and the cluster-shaped compatibility view.
Under the current uncalibrated policy every candidate decision is `REVIEW`; no persistent
registry entity is promoted.

## 14. Intermediate and Core Models

```bash
make core
```

This builds the ONSUD bridge if missing, location/geography intermediates, atomic PPD/EPC
facts, recommendation facts, and certificate-grain recommendation aggregates. It does not
build future marts or graph exports.

## 15. Audit and Source-Reconciliation Models

Audit/source reconciliation is deliberately built before identity work in section 7. It
can be rerun independently without rebuilding identity or core:

```bash
make silver-audit
make silver-audit-tests
```

All 50 current dbt model relations should then exist. Verify against the dbt manifest,
not a hand-maintained table list; `bin/run_pipeline.sh` performs this closure check.

## 16. Calibration Sample

Create or verify the deterministic blank-label sample:

```bash
make calibration-sample
```

The positional CLI action is required:

```bash
.venv/bin/python -m epc_v5.calibrate_identity create-sample \
  --database output/duckdb/epc_v5.duckdb \
  --threads 1 \
  --memory-limit 8GB \
  --temp-directory output/tmp/calibration \
  --max-temp-size 120GB
```

No label is inferred. The current successful sample has 1,559 rows and a manifest-bound
CSV checksum.

## 17. Manual Label Import and Evaluation

Review the exported CSV outside the pipeline. Preserve row keys and fill only the allowed
manual adjudication fields. Then run:

```bash
make calibration-import LABELS_PATH=/absolute/path/to/adjudicated-sample.csv
make calibration-evaluate
```

Label import is not idempotent: importing the same file again creates a new version of
active label evidence. Evaluation is evidence-only and must not promote registry entities.

## 18. Python, Static, and Parse Validation

```bash
make python-tests
make pip-check
make lint
make dbt-parse
```

`make test` means Python tests plus dbt parse. It intentionally does not claim to run dbt
data tests. `make lint` runs Ruff and SQLFluff over project Python/models/macros.

## 19. Targeted dbt Data Tests

Run major stations independently:

```bash
make source-tests
make silver-tests
make identity-candidate-tests
make identity-data-tests
make scoring-data-tests
make core-data-tests
make calibration-data-tests
make contract-tests
```

These validate, respectively:

- generic source/seed contracts plus source release/file/container controls;
- Silver typing, quarantine, and source conservation;
- candidate route, endpoint, pair, and rule closure;
- score/decision, alternatives, hypotheses, assignments, and no-promotion policy;
- Python-owned Splink runs/scores/publications and calibration source-table contracts;
- atomic facts, recommendations, coordinates, geography, and location closure;
- deterministic sample closure and manual-only label provenance.
- narrow macro, parsing, key, geography, and decision-policy fixtures.

## 20. Full Validation Strategy

```bash
make data-tests
make full-validate
```

`data-tests` runs bounded groups sequentially rather than launching all tests as one
uncontrolled process. `full-validate` adds pip, Python, Ruff, SQLFluff, and dbt parse.
The optimized endpoint-closure test unions both pair endpoints and performs one anti-join
to the current observation population, allowing the current 135-test `tag:identity` group
to run at the normal 8GB profile.

## 21. Restart and Idempotency Rules

| Stage | Safe restart behavior |
|---|---|
| Source import | Content-addressed files/members already loaded are skipped. |
| Silver tables | Deterministic replace; expensive, so resume skips existing relations. |
| Silver reconciliation publication | Repeatable after all fresh reconciliation gates pass. |
| Libpostal parse | Deterministic keys resume missing results; successful publication is skipped. |
| Candidate generation | Deterministic incremental keys avoid duplicate observations/pairs. |
| Benchmark | Not idempotent; every invocation creates a new artifact/run. |
| National scoring | Immutable; complete publication is skipped, partial state stops. |
| Downstream/core dbt | Resume skips complete relation sets; individual dbt models remain rebuildable. |
| Calibration sample | Successful manifest and export hash are verified before skipping. |
| Label import/evaluation | Human-governed and deliberately excluded from automated resume. |

The orchestrator does not infer labels, choose among ambiguous benchmark artifacts, repair
partial national output, or drop evidence.

## 22. Splink Scratch and Failed Runs

Preserve all benchmark/national audit rows, including failed runs. Inspect non-authoritative
scratch read-only:

```bash
make splink-scratch-inventory
```

Do not drop `identity_work.__splink__*` relations by wildcard. The current table names do
not encode a durable run owner, and `identity_work` also contains calibration scratch.
A cleanup requires all of the following:

1. prove no dbt, DuckDB, Splink, calibration, or pipeline writer is active;
2. identify an exact table list and its owning run;
3. verify successful national publication and candidate/score closure;
4. verify benchmark model and calibration export hashes;
5. preserve failed/successful run rows and all authoritative output tables;
6. obtain explicit operator approval for that exact list.

The inventory command intentionally performs no deletion. Future scoring should use a
run-specific scratch database with an ownership manifest before automatic cleanup is added.

## 23. Current Limitations

- Calibration labels have not been imported; registry promotion remains disabled.
- Marts and graph exports are not implemented.
- The current published model retains its historical `epcv4_` linker UID; this is immutable
  artifact evidence, not a reason to rescore.
- The current failed national run has a retained failure message but no completion timestamp.
  Preserve it as audit evidence unless a separately approved audit correction is made.
- Splink/calibration scratch is retained pending positive run-ownership proof.
