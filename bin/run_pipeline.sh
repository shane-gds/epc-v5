#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:-resume}"
case "$MODE" in
  clean-build|resume) ;;
  *) printf 'Usage: %s [clean-build|resume]\n' "$0" >&2; exit 2 ;;
esac

PYTHON="${PYTHON:-.venv/bin/python}"
DB_PATH="${EPC_V5_DUCKDB_PATH:-output/duckdb/epc_v5.duckdb}"
export EPC_V5_DUCKDB_PATH="$DB_PATH"
export EPC_V5_DBT_THREADS="${EPC_V5_DBT_THREADS:-1}"
export EPC_V5_DUCKDB_THREADS="${EPC_V5_DUCKDB_THREADS:-1}"
export EPC_V5_MEMORY_LIMIT="${EPC_V5_MEMORY_LIMIT:-8GB}"
export EPC_V5_MAX_TEMP_SIZE="${EPC_V5_MAX_TEMP_SIZE:-120GB}"
export EPC_V5_SPLINK_TEMP_DIR="${EPC_V5_SPLINK_TEMP_DIR:-output/tmp/splink}"
export EPC_V5_CALIBRATION_TEMP_DIR="${EPC_V5_CALIBRATION_TEMP_DIR:-output/tmp/calibration}"
export SPLINK_THREADS="${SPLINK_THREADS:-1}"
export SPLINK_SALTING_PARTITIONS="${SPLINK_SALTING_PARTITIONS:-2}"
MODEL_PATH="${MODEL_PATH:-}"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
trap 'fail "pipeline stopped at line $LINENO"' ERR

command -v flock >/dev/null || fail "flock is required"
mkdir -p "$(dirname "$DB_PATH")" "$EPC_V5_SPLINK_TEMP_DIR" \
  "$EPC_V5_CALIBRATION_TEMP_DIR" output/identity
exec 9>"${DB_PATH}.pipeline.lock"
flock -n 9 || fail "another EPC v5 pipeline owns ${DB_PATH}.pipeline.lock"

if [[ ! -x "$PYTHON" ]]; then
  if [[ "$MODE" == clean-build ]]; then
    log "Creating the Python environment"
    make setup
  else
    fail "missing $PYTHON; run make setup"
  fi
fi

if [[ "$MODE" == clean-build && -e "$DB_PATH" ]]; then
  fail "clean-build refuses to overwrite existing database: $DB_PATH"
fi
if [[ "$MODE" == resume && ! -f "$DB_PATH" ]]; then
  fail "resume requires an existing database: $DB_PATH"
fi

require_free_gib() {
  local path=$1 required=$2 available
  available=$(df -Pk "$path" | awk 'NR == 2 {print int($4 / 1024 / 1024)}')
  (( available >= required )) || fail "${available}GiB free; this stage requires at least ${required}GiB"
}

if [[ "$MODE" == clean-build ]]; then
  require_free_gib "$(dirname "$DB_PATH")" 300
else
  require_free_gib "$(dirname "$DB_PATH")" 25
fi

spill_gib=$(
  "$PYTHON" - "$EPC_V5_MAX_TEMP_SIZE" <<'PY'
import re
import sys

match = re.fullmatch(r"\s*(\d+)\s*(GB|GiB)\s*", sys.argv[1], re.IGNORECASE)
if not match:
    raise SystemExit("EPC_V5_MAX_TEMP_SIZE must be an integer GB/GiB value")
print(int(match.group(1)))
PY
)

query_scalar() {
  "$PYTHON" - "$DB_PATH" "$1" <<'PY'
import sys
import duckdb

database, sql = sys.argv[1:]
connection = duckdb.connect(database, read_only=True)
try:
    row = connection.execute(sql).fetchone()
    print("" if row is None or row[0] is None else row[0])
finally:
    connection.close()
PY
}

has_relation() {
  [[ "$(query_scalar "select count(*) from information_schema.tables where table_schema = '$1' and table_name = '$2'")" == 1 ]]
}

all_relations_present() {
  local relation schema table
  for relation in "$@"; do
    schema="${relation%%.*}"
    table="${relation#*.}"
    has_relation "$schema" "$table" || return 1
  done
}

log "Using $DB_PATH with ${EPC_V5_MEMORY_LIMIT}, ${EPC_V5_DUCKDB_THREADS} DuckDB thread(s), ${EPC_V5_MAX_TEMP_SIZE} spill"
make dbt-deps

source_state="INCOMPLETE"
if [[ -f "$DB_PATH" ]] \
  && has_relation audit audit_dataset_release \
  && has_relation audit audit_source_file \
  && has_relation audit audit_source_file_container; then
  source_state=$(
    "$PYTHON" - "$DB_PATH" config/source_import.yml <<'PY'
import hashlib
import sys
import zipfile
from pathlib import Path

import duckdb
import yaml

from epc_v5.import_sources import ROUTES

database, config_path = sys.argv[1:]
config_file = Path(config_path).resolve()
config = yaml.safe_load(config_file.read_text())
data_root = Path(config["data_root"])
if not data_root.is_absolute():
    data_root = config_file.parent.parent / data_root
connection = duckdb.connect(database, read_only=True)
state = "COMPLETE"
for target_name, source in config["sources"].items():
    path = data_root / source["file"]
    if not path.is_file():
        state = "DRIFT"
        break
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(16 * 1024 * 1024):
            digest.update(chunk)
    routes = ROUTES[target_name]
    parser_contract = (
        "zip_archive_v1"
        if any(route.member_pattern is not None for route in routes)
        else routes[0].parser_contract_version
    )
    registered_parents = connection.execute(
        """
        select
            source_file.byte_size,
            source_file.content_sha256,
            source_file.parser_contract_version,
            source_file.ingestion_status
        from audit.audit_dataset_release as release
        inner join audit.audit_source_file as source_file
            on release.dataset_release_id = source_file.dataset_release_id
        where release.dataset_code = ?
          and release.publisher = ?
          and release.release_label = ?
          and source_file.parent_source_file_id is null
        """,
        [source["dataset_code"], source["publisher"], source["release_label"]],
    ).fetchall()
    if any(
        row[3] == "LOADED"
        and (
            row[0] != path.stat().st_size
            or row[1] != digest.hexdigest()
            or row[2] != parser_contract
        )
        for row in registered_parents
    ):
        state = "DRIFT"
        break
    parent_rows = connection.execute(
        """
        select source_file.source_file_id, release.status
        from audit.audit_dataset_release as release
        inner join audit.audit_source_file as source_file
            on release.dataset_release_id = source_file.dataset_release_id
        where release.dataset_code = ?
          and release.publisher = ?
          and release.release_label = ?
          and source_file.parent_source_file_id is null
          and source_file.file_name = ?
          and source_file.byte_size = ?
          and source_file.content_sha256 = ?
          and source_file.parser_contract_version = ?
          and source_file.ingestion_status = 'LOADED'
        """,
        [
            source["dataset_code"],
            source["publisher"],
            source["release_label"],
            path.name,
            path.stat().st_size,
            digest.hexdigest(),
            parser_contract,
        ],
    ).fetchall()
    if len(parent_rows) != 1:
        matching_registered_parent = any(
            row[0] == path.stat().st_size
            and row[1] == digest.hexdigest()
            and row[2] == parser_contract
            for row in registered_parents
        )
        state = "INCOMPLETE" if matching_registered_parent or not registered_parents else "DRIFT"
        break
    archive_routes = [route for route in routes if route.member_pattern is not None]
    if archive_routes:
        with zipfile.ZipFile(path) as archive:
            expected_members = {
                member.filename
                for member in archive.infolist()
                if not member.is_dir()
                and any(route.member_pattern.fullmatch(member.filename) for route in archive_routes)
            }
        child_rows = connection.execute(
            """
            select
                membership.source_member_path,
                child.parser_contract_version,
                child.ingestion_status
            from audit.audit_source_file_container as membership
            inner join audit.audit_source_file as child
                on membership.child_source_file_id = child.source_file_id
            where membership.parent_source_file_id = ?
            """,
            [parent_rows[0][0]],
        ).fetchall()
        registered_members = {row[0] for row in child_rows}
        if expected_members != registered_members:
            state = "DRIFT"
            break
        for file_name, child_contract, child_status in child_rows:
            matching_routes = [
                route for route in archive_routes if route.member_pattern.fullmatch(file_name)
            ]
            if (
                len(matching_routes) != 1
                or child_contract != matching_routes[0].parser_contract_version
            ):
                state = "DRIFT"
                break
            if child_status != "LOADED":
                state = "DRIFT"
                break
        if state != "COMPLETE":
            break
    if parent_rows[0][1] != "LOADED":
        state = "INCOMPLETE"
        break
connection.close()
print(state)
PY
  )
fi
source_changed=0
if [[ "$MODE" == resume && "$source_state" == DRIFT ]]; then
  fail "configured source content or parser contract differs from the loaded release; register a new release instead of appending into the existing snapshot"
fi
if [[ "$MODE" == clean-build ]] || [[ "$source_state" == INCOMPLETE ]]; then
  log "Importing registered source files"
  make import
  source_changed=1
else
  log "Configured source release/file/hash/parser manifests are complete; skipping import"
fi

silver_relations=(
  silver.stg_epc_certificate_observation
  silver.stg_epc_recommendation_observation
  silver.stg_pp_transaction_observation
  silver.stg_onsud_uprn_allocation
  silver.stg_lad_name_code_reference
  silver.stg_lpa_name_code_reference
)
silver_changed=0
if (( source_changed == 1 )) || ! all_relations_present "${silver_relations[@]}"; then
  log "Building Silver observations"
  make silver
  silver_changed=1
else
  log "Silver observations already materialized; skipping rebuild"
fi

silver_audit_relations=(
  intermediate.bridge_onsud_allocation_source_record
  audit.quarantine_source_record
  audit.audit_silver_quality_profile
  audit.audit_source_file_silver_reconciliation
)
if (( silver_changed == 1 )) || ! all_relations_present "${silver_audit_relations[@]}"; then
  log "Building and publishing Silver reconciliation"
  make silver-audit
else
  log "Silver reconciliation exists; validating without rebuilding"
  make silver-audit-tests
  "$PYTHON" -m epc_v5 publish-silver-reconciliation \
    --config config/source_import.yml --database "$DB_PATH"
fi

parse_complete=0
if has_relation silver int_epc_address_libpostal_route_manifest \
  && has_relation identity identity_address_parse_publication; then
  parse_complete=$(query_scalar "select count(*) from identity.identity_address_parse_publication p inner join identity.identity_address_parse_run r using (address_parse_run_key) where p.publication_name = 'CURRENT_IDENTITY' and r.run_status = 'SUCCEEDED'")
fi
parse_changed=0
if (( silver_changed == 1 || parse_complete == 0 )); then
  log "Preparing and executing selective libpostal parsing"
  make libpostal-setup
  make libpostal-parse
  parse_changed=1
else
  log "Successful selective libpostal publication exists; skipping"
fi

candidate_relations=(
  identity.int_identity_current_run
  identity.identity_run_manifest
  identity.int_identity_address_parse
  identity.int_identity_observation
  identity.identity_libpostal_candidate_block_profile
  identity.identity_scoring_input
  identity.identity_candidate_rule_hit
  identity.identity_candidate_pair
  identity.identity_candidate_generation_audit
)
candidate_complete=0
if all_relations_present "${candidate_relations[@]}"; then
  candidate_complete=$(query_scalar "select count(*) from (select 1 from identity.identity_candidate_pair p inner join identity.int_identity_current_run r using (identity_run_key) limit 1)")
fi
candidate_changed=0
if (( parse_changed == 1 || candidate_complete == 0 )); then
  log "Building identity observations and candidates"
  make identity-candidates
  candidate_changed=1
else
  log "Current-run candidate population exists; validating without rebuilding"
  make identity-candidate-tests
fi

select_benchmark_model() {
  "$PYTHON" - "$DB_PATH" "$MODEL_PATH" <<'PY'
import hashlib
import sys
from pathlib import Path

import duckdb

database, supplied = sys.argv[1:]
connection = duckdb.connect(database, read_only=True)
tables = {
    (row[0], row[1])
    for row in connection.execute(
        "select table_schema, table_name from information_schema.tables"
    ).fetchall()
}
if ("identity", "identity_splink_run") not in tables:
    connection.close()
    raise SystemExit(4)
rows = connection.execute(
    """
    select r.model_path, r.model_sha256
    from identity.identity_splink_run as r
    inner join identity.int_identity_current_run as current_run
        on r.identity_run_key = current_run.identity_run_key
       and r.model_version = current_run.comparison_model_version
    where r.run_mode = 'BENCHMARK'
      and r.run_status = 'SUCCEEDED'
      and r.model_path is not null
      and r.model_sha256 is not null
    order by r.completed_at desc
    """
).fetchall()
connection.close()
if not rows:
    raise SystemExit(4)

if supplied:
    supplied_path = Path(supplied).resolve()
    matches = [row for row in rows if Path(row[0]).resolve() == supplied_path]
    if len(matches) != 1:
        print("MODEL_PATH is not a successful benchmark for the current identity run", file=sys.stderr)
        raise SystemExit(5)
    selected = matches[0]
elif len(rows) == 1:
    selected = rows[0]
else:
    print("Multiple successful benchmark artifacts exist; set MODEL_PATH explicitly", file=sys.stderr)
    for path, sha256 in rows:
        print(f"  {path} | {sha256}", file=sys.stderr)
    raise SystemExit(5)

path = Path(selected[0])
if not path.is_file():
    print(f"Benchmark artifact is missing: {path}", file=sys.stderr)
    raise SystemExit(6)
actual = hashlib.sha256(path.read_bytes()).hexdigest()
if actual != selected[1]:
    print(f"Benchmark artifact hash mismatch: {path}", file=sys.stderr)
    raise SystemExit(6)
print(path)
PY
}

set +e
selected_model=$(select_benchmark_model)
model_status=$?
set -e
if (( model_status == 4 )); then
  require_free_gib "$EPC_V5_SPLINK_TEMP_DIR" "$((spill_gib + 20))"
  log "No successful current-run benchmark exists; training one benchmark"
  make splink-benchmark \
    SPLINK_THREADS="$SPLINK_THREADS" \
    SPLINK_SALTING_PARTITIONS="$SPLINK_SALTING_PARTITIONS"
  selected_model=$(select_benchmark_model)
elif (( model_status != 0 )); then
  fail "benchmark artifact selection failed"
fi
MODEL_PATH="$selected_model"
log "Selected benchmark model: $MODEL_PATH"

national_state=$(
  "$PYTHON" - "$DB_PATH" <<'PY'
import sys
import duckdb

connection = duckdb.connect(sys.argv[1], read_only=True)
tables = {
    (row[0], row[1])
    for row in connection.execute(
        "select table_schema, table_name from information_schema.tables"
    ).fetchall()
}
if ("identity", "identity_splink_publication") not in tables:
    connection.close()
    print("ABSENT")
    raise SystemExit(0)
publication = connection.execute(
    """
    select p.splink_run_id, p.model_sha256
    from identity.identity_splink_publication as p
    inner join identity.int_identity_current_run as r using (identity_run_key)
    """
).fetchall()
if len(publication) == 1:
    run_id, model_hash = publication[0]
    candidate_count = connection.execute(
        "select count(*) from identity.identity_candidate_pair p inner join identity.int_identity_current_run r using (identity_run_key)"
    ).fetchone()[0]
    score_count, distinct_count = connection.execute(
        "select count(*), count(distinct candidate_pair_key) from identity.identity_match_score where splink_run_id = ? and model_sha256 = ?",
        [run_id, model_hash],
    ).fetchone()
    state = "COMPLETE" if candidate_count == score_count == distinct_count else "PARTIAL"
elif not publication:
    score_count = 0
    if ("identity", "identity_match_score") in tables:
        score_count = connection.execute(
            "select count(*) from identity.identity_match_score s inner join identity.int_identity_current_run r using (identity_run_key)"
        ).fetchone()[0]
    state = "ABSENT" if score_count == 0 else "PARTIAL"
else:
    state = "PARTIAL"
connection.close()
print(state)
PY
)
case "$national_state" in
  COMPLETE) log "Immutable national publication has exact candidate/score closure; skipping" ;;
  ABSENT)
    require_free_gib "$EPC_V5_SPLINK_TEMP_DIR" "$((spill_gib + 20))"
    log "Running national scoring with $MODEL_PATH"
    make splink-national MODEL_PATH="$MODEL_PATH" SPLINK_THREADS="$SPLINK_THREADS"
    national_changed=1
    ;;
  *) fail "national publication is partial or ambiguous; manual recovery is required" ;;
esac

downstream_relations=(
  identity.identity_current_match_score
  identity.identity_match_decision
  identity.identity_current_match_decision
  identity.identity_target_hypothesis
  identity.identity_target_alternative_l
  identity.identity_target_alternative_r
  identity.identity_target_alternative
  identity.identity_target_alternative_ranked
  identity.identity_candidate_alternative
  identity.identity_observation_candidate_summary_l
  identity.identity_observation_candidate_summary_r
  identity.identity_observation_candidate_summary
  identity.identity_hypothesis
  identity.bridge_source_record_entity_assignment
  identity.identity_cluster_membership
)
national_changed=${national_changed:-0}
if (( national_changed == 1 )) || ! all_relations_present "${downstream_relations[@]}"; then
  log "Building downstream identity evidence"
  make identity-downstream
else
  log "Downstream identity relations already materialized; skipping rebuild"
fi

core_relations=(
  core.int_required_uprn core.int_uprn_location core.int_required_coordinate_pair
  core.int_coordinate_wgs84 core.int_geography_reference_profile
  core.int_postcode_coordinate_point core.int_postcode_sector_coordinate
  core.int_postcode_coordinate core.dim_geography core.fct_epc_certificate
  core.fct_sale_transaction core.fct_epc_recommendation_observation
  core.int_epc_recommendation_observed_agg core.int_epc_recommendation_agg
)
if (( source_changed == 1 )) || ! all_relations_present "${core_relations[@]}"; then
  log "Building intermediate and core relations"
  make core
else
  log "Core relations already materialized; skipping rebuild"
fi

calibration_state=$(
  "$PYTHON" - "$DB_PATH" <<'PY'
import hashlib
import sys
from pathlib import Path

import duckdb

connection = duckdb.connect(sys.argv[1], read_only=True)
tables = {
    (row[0], row[1])
    for row in connection.execute(
        "select table_schema, table_name from information_schema.tables"
    ).fetchall()
}
if ("identity", "identity_calibration_sample_manifest") not in tables:
    connection.close()
    print("ABSENT")
    raise SystemExit(0)
row = connection.execute(
    """
    select manifest.export_path, manifest.export_sha256
    from identity.identity_calibration_sample_manifest as manifest
    inner join identity.int_identity_current_run as current_run using (identity_run_key)
    where manifest.sample_status = 'SUCCEEDED'
    order by manifest.completed_at desc
    limit 1
    """
).fetchone()
connection.close()
if row is None:
    print("ABSENT")
else:
    path = Path(row[0])
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != row[1]:
        print("INVALID")
    else:
        print("COMPLETE")
PY
)
case "$calibration_state" in
  COMPLETE) log "Calibration sample and export hash verified; skipping recreation" ;;
  ABSENT)
    require_free_gib "$EPC_V5_CALIBRATION_TEMP_DIR" "$((spill_gib + 20))"
    log "Creating deterministic blank-label calibration sample"
    make calibration-sample
    ;;
  *) fail "calibration manifest/export mismatch requires manual investigation" ;;
esac

log "Running complete bounded validation"
make full-validate

model_closure=$(
  "$PYTHON" - "$DB_PATH" <<'PY'
import json
import sys
from pathlib import Path

import duckdb

manifest = json.loads(Path("target/manifest.json").read_text())
models = [node for node in manifest["nodes"].values() if node["resource_type"] == "model"]
expected = {(node["schema"], node["alias"]) for node in models}
connection = duckdb.connect(sys.argv[1], read_only=True)
present = set(connection.execute("select table_schema, table_name from information_schema.tables").fetchall())
connection.close()
print(len(expected - present), len(expected))
PY
)
read -r missing_model_count expected_model_count <<<"$model_closure"
(( missing_model_count == 0 )) || fail "dbt model closure failed: ${missing_model_count} missing of ${expected_model_count}"

log "PIPELINE COMPLETE: 0 missing of ${expected_model_count} dbt models"
log "Manual next step: adjudicate calibration labels; no labels were inferred or imported"
