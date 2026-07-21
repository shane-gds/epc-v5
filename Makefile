SHELL := /usr/bin/bash
PYTHON := .venv/bin/python
PIP := .venv/bin/pip
DBT := .venv/bin/dbt

DB_PATH ?= $(or $(EPC_V5_DUCKDB_PATH),output/duckdb/epc_v5.duckdb)
PROFILES_DIR ?= .
MEMORY_LIMIT ?= $(or $(EPC_V5_MEMORY_LIMIT),8GB)
MAX_TEMP_SIZE ?= $(or $(EPC_V5_MAX_TEMP_SIZE),120GB)
DBT_THREADS ?= $(or $(EPC_V5_DBT_THREADS),1)
DUCKDB_THREADS ?= $(or $(EPC_V5_DUCKDB_THREADS),1)
SPLINK_THREADS ?= 1
SPLINK_SALTING_PARTITIONS ?= 2
SPLINK_SAMPLE_HEX_MAX ?= 03
SPLINK_U_PAIRS ?= 1000000
SPLINK_TEMP_DIR ?= $(or $(EPC_V5_SPLINK_TEMP_DIR),output/tmp/splink)
CALIBRATION_TEMP_DIR ?= $(or $(EPC_V5_CALIBRATION_TEMP_DIR),output/tmp/calibration)
DUCKDB_UI_PORT ?= 4214
LIBPOSTAL_SAMPLE_SIZE ?= 10000
LIBPOSTAL_BATCH_SIZE ?= 5000

DBT_ENV := EPC_V5_DUCKDB_PATH="$(DB_PATH)" \
	EPC_V5_MEMORY_LIMIT="$(MEMORY_LIMIT)" \
	EPC_V5_MAX_TEMP_SIZE="$(MAX_TEMP_SIZE)" \
	EPC_V5_DBT_THREADS="$(DBT_THREADS)" \
	EPC_V5_DUCKDB_THREADS="$(DUCKDB_THREADS)"

.PHONY: setup install dbt-deps debug import seed silver silver-audit \
	silver-audit-tests libpostal-setup libpostal-benchmark libpostal-parse \
	identity-candidates identity-candidate-tests splink-benchmark splink-models \
	splink-national identity-downstream core calibration-sample calibration-import \
	calibration-evaluate contract-tests source-tests silver-tests scoring-data-tests \
	identity-data-tests core-data-tests calibration-data-tests data-tests python-tests \
	dbt-parse pip-check test lint format \
	full-validate pipeline-resume pipeline-clean-build splink-scratch-inventory clean ui \
	ui-ssh help

setup: ## Create the Python 3.12 venv, install packages, and fetch dbt packages
	python3.12 -m venv .venv
	$(PIP) install --upgrade pip setuptools wheel
	$(PIP) install -e ".[dev,graph,parquet]"
	$(DBT) deps --profiles-dir $(PROFILES_DIR)

install: ## Install project and development packages into an existing venv
	$(PIP) install -e ".[dev,graph,parquet]"
	$(DBT) deps --profiles-dir $(PROFILES_DIR)

dbt-deps: ## Fetch dbt package dependencies
	$(DBT) deps --profiles-dir $(PROFILES_DIR)

debug: ## Validate the dbt profile and DuckDB connection
	$(DBT_ENV) $(DBT) debug --profiles-dir $(PROFILES_DIR)

import: ## Import configured source files into audited Bronze tables
	$(PYTHON) -m epc_v5 import-sources --config config/source_import.yml \
		--database "$(DB_PATH)"

seed: ## Load reference seeds such as the identity blocking policy
	$(DBT_ENV) $(DBT) seed --profiles-dir $(PROFILES_DIR)

silver: seed ## Build the six typed Silver source-observation models
	$(DBT_ENV) $(DBT) run --profiles-dir $(PROFILES_DIR) --select \
		stg_epc_certificate_observation stg_epc_recommendation_observation \
		stg_pp_transaction_observation stg_onsud_uprn_allocation \
		stg_lad_name_code_reference stg_lpa_name_code_reference

silver-audit: ## Build Silver quarantine, ONSUD bridge, and reconciliation gates
	$(DBT_ENV) $(DBT) run --profiles-dir $(PROFILES_DIR) --select \
		bridge_onsud_allocation_source_record quarantine_source_record \
		audit_silver_quality_profile audit_source_file_silver_reconciliation
	$(MAKE) silver-audit-tests
	$(PYTHON) -m epc_v5 publish-silver-reconciliation \
		--config config/source_import.yml --database "$(DB_PATH)"

silver-audit-tests: ## Test Silver source conservation and audit model contracts
	$(DBT_ENV) $(DBT) test --profiles-dir $(PROFILES_DIR) \
		--indirect-selection cautious --select \
		bridge_onsud_allocation_source_record quarantine_source_record \
		audit_silver_quality_profile audit_source_file_silver_reconciliation \
		reconcile_onsud_source_bridge reconcile_silver_source_outcomes \
		silver_quarantine_disjoint

libpostal-setup: ## Build or verify the pinned native libpostal runtime
	./scripts/setup_libpostal_benchmark.sh

libpostal-benchmark: ## Run the shadow EPC/PPD libpostal benchmark
	$(PYTHON) -m epc_v5.benchmark_libpostal --database "$(DB_PATH)" \
		--sample-size $(LIBPOSTAL_SAMPLE_SIZE)

libpostal-parse: ## Build and execute the selective EPC flat-trap parse
	$(DBT_ENV) $(DBT) run --profiles-dir $(PROFILES_DIR) --select \
		int_epc_address_libpostal_route int_epc_address_libpostal_route_manifest
	$(PYTHON) -m epc_v5 parse-identity-addresses --database "$(DB_PATH)" \
		--batch-size $(LIBPOSTAL_BATCH_SIZE)

identity-candidates: ## Build current identity inputs and strict candidate pairs
	$(DBT_ENV) $(DBT) seed --profiles-dir $(PROFILES_DIR) \
		--select identity_blocking_policy
	$(DBT_ENV) $(DBT) run --profiles-dir $(PROFILES_DIR) --select \
		int_identity_current_run identity_run_manifest int_identity_address_parse \
		int_identity_observation identity_libpostal_candidate_block_profile \
		identity_scoring_input identity_candidate_rule_hit identity_candidate_pair \
		identity_candidate_generation_audit
	$(MAKE) identity-candidate-tests

identity-candidate-tests: ## Run bounded route, observation, and candidate closure tests
	$(DBT_ENV) $(DBT) test --indirect-selection cautious \
		--profiles-dir $(PROFILES_DIR) --select \
		int_epc_address_libpostal_route int_epc_address_libpostal_route_manifest \
		int_identity_address_parse int_identity_observation \
		identity_libpostal_candidate_block_profile identity_candidate_rule_hit \
		identity_candidate_pair reconcile_identity_observation_population \
		epc_address_libpostal_route_contract identity_address_parse_population_closure \
		identity_libpostal_candidate_block_limits \
		identity_libpostal_candidate_rule_contract identity_candidate_enabled_rules_only \
		identity_candidate_endpoint_closure identity_candidate_pair_closure \
		identity_candidate_rules_mutually_exclusive

splink-benchmark: ## Train and score one governed Splink benchmark artifact
	$(PYTHON) -m epc_v5.score_identity --mode benchmark --database "$(DB_PATH)" \
		--threads $(SPLINK_THREADS) --memory-limit $(MEMORY_LIMIT) \
		--temp-directory "$(SPLINK_TEMP_DIR)" --max-temp-size $(MAX_TEMP_SIZE) \
		--salting-partitions $(SPLINK_SALTING_PARTITIONS) \
		--sample-hex-max $(SPLINK_SAMPLE_HEX_MAX) --u-pairs $(SPLINK_U_PAIRS)

splink-models: ## List successful benchmark artifacts for the current identity run
	$(PYTHON) -c "import duckdb, sys; c=duckdb.connect(sys.argv[1], read_only=True); rows=c.execute(\"select r.splink_run_id, r.model_path, r.model_sha256, r.completed_at from identity.identity_splink_run r inner join identity.int_identity_current_run i using (identity_run_key) where r.run_mode='BENCHMARK' and r.run_status='SUCCEEDED' and r.model_version=i.comparison_model_version order by r.completed_at desc\").fetchall(); print('\\n'.join(' | '.join(map(str, row)) for row in rows))" "$(DB_PATH)"

splink-national: ## Score all candidates; requires MODEL_PATH from splink-models
	@test -n "$(MODEL_PATH)" || { echo "MODEL_PATH is required; run 'make splink-models'" >&2; exit 2; }
	$(PYTHON) -m epc_v5.score_identity --mode national --database "$(DB_PATH)" \
		--model-path "$(MODEL_PATH)" --threads $(SPLINK_THREADS) \
		--memory-limit $(MEMORY_LIMIT) --temp-directory "$(SPLINK_TEMP_DIR)" \
		--max-temp-size $(MAX_TEMP_SIZE)

identity-downstream: ## Build published scores, decisions, alternatives, hypotheses, and assignments
	$(DBT_ENV) $(DBT) run --profiles-dir $(PROFILES_DIR) --select \
		identity_current_match_score identity_match_decision \
		identity_current_match_decision identity_target_hypothesis \
		identity_target_alternative_l identity_target_alternative_r \
		identity_target_alternative identity_target_alternative_ranked \
		identity_candidate_alternative identity_observation_candidate_summary_l \
		identity_observation_candidate_summary_r identity_observation_candidate_summary \
		identity_hypothesis bridge_source_record_entity_assignment \
		identity_cluster_membership

core: ## Build the ONSUD bridge, geography models, atomic facts, and aggregates
	$(DBT_ENV) $(DBT) run --profiles-dir $(PROFILES_DIR) --select \
		bridge_onsud_allocation_source_record int_required_uprn int_uprn_location \
		int_required_coordinate_pair int_coordinate_wgs84 \
		int_geography_reference_profile int_postcode_coordinate_point \
		int_postcode_sector_coordinate int_postcode_coordinate dim_geography \
		fct_epc_certificate fct_sale_transaction fct_epc_recommendation_observation \
		int_epc_recommendation_observed_agg int_epc_recommendation_agg

calibration-sample: ## Create or verify the deterministic blank-label calibration sample
	$(PYTHON) -m epc_v5.calibrate_identity create-sample --database "$(DB_PATH)" \
		--threads 1 --memory-limit $(MEMORY_LIMIT) \
		--temp-directory "$(CALIBRATION_TEMP_DIR)" --max-temp-size $(MAX_TEMP_SIZE)

calibration-import: ## Import manually adjudicated labels; requires LABELS_PATH
	@test -n "$(LABELS_PATH)" || { echo "LABELS_PATH is required" >&2; exit 2; }
	$(PYTHON) -m epc_v5.calibrate_identity import-labels --database "$(DB_PATH)" \
		--labels-path "$(LABELS_PATH)" --threads 1 --memory-limit $(MEMORY_LIMIT) \
		--temp-directory "$(CALIBRATION_TEMP_DIR)" --max-temp-size $(MAX_TEMP_SIZE)

calibration-evaluate: ## Evaluate imported manual labels without promoting registry entities
	$(PYTHON) -m epc_v5.calibrate_identity evaluate --database "$(DB_PATH)" \
		--threads 1 --memory-limit $(MEMORY_LIMIT) \
		--temp-directory "$(CALIBRATION_TEMP_DIR)" --max-temp-size $(MAX_TEMP_SIZE)

contract-tests: ## Run narrow parsing, key, geography, and decision-policy fixtures
	$(DBT_ENV) $(DBT) test --profiles-dir $(PROFILES_DIR) --select \
		uk_postcode_macro_fixtures strict_integer_macro_fixtures \
		recommendation_parent_classification_fixtures \
		onsud_conflict_classification_fixtures epc_conflict_classification_fixtures \
		geography_reference_fixtures coordinate_key_fixture \
		coordinate_algorithm_fixtures identity_assignment_publication_fixtures \
		approximate_coordinates_have_no_official_geography \
		coordinate_transform_runtime_version core_atomic_facts_have_no_subject_identity \
		epc_recommendation_aggregate_has_no_entity_or_location

source-tests: ## Test source-file, container, and selected-release controls
	$(DBT_ENV) $(DBT) test --profiles-dir $(PROFILES_DIR) --select \
		"source:*" identity_blocking_policy
	$(DBT_ENV) $(DBT) test --profiles-dir $(PROFILES_DIR) --select \
		source_file_content_grain source_file_container_closure \
		selected_onsud_release_exactly_one selected_geography_reference_releases_exactly_one

silver-tests: ## Test Silver staging, quarantine, and reconciliation contracts
	$(DBT_ENV) $(DBT) test --profiles-dir $(PROFILES_DIR) \
		--indirect-selection cautious --select \
		stg_epc_certificate_observation stg_epc_recommendation_observation \
		stg_pp_transaction_observation stg_onsud_uprn_allocation \
		stg_lad_name_code_reference stg_lpa_name_code_reference \
		bridge_onsud_allocation_source_record quarantine_source_record \
		audit_silver_quality_profile audit_source_file_silver_reconciliation \
		reconcile_onsud_source_bridge reconcile_silver_source_outcomes \
		silver_quarantine_disjoint

scoring-data-tests: ## Test Python-owned Splink and calibration source contracts
	$(DBT_ENV) $(DBT) test --profiles-dir $(PROFILES_DIR) --select \
		source:identity_scoring source:identity_calibration

identity-data-tests: ## Run the complete bounded-memory identity test group
	$(DBT_ENV) $(DBT) test --profiles-dir $(PROFILES_DIR) --select tag:identity

core-data-tests: ## Run core fact, coordinate, and geography tests
	$(DBT_ENV) $(DBT) test --profiles-dir $(PROFILES_DIR) --select tag:core

calibration-data-tests: ## Verify sample closure and manual-only label provenance
	$(DBT_ENV) $(DBT) test --profiles-dir $(PROFILES_DIR) --select \
		identity_calibration_sample_contract identity_calibration_labels_manual_only

data-tests: ## Run bounded dbt data-test groups sequentially
	$(MAKE) contract-tests
	$(MAKE) source-tests
	$(MAKE) silver-tests
	$(MAKE) scoring-data-tests
	$(MAKE) identity-candidate-tests
	$(MAKE) identity-data-tests
	$(MAKE) core-data-tests
	$(MAKE) calibration-data-tests

python-tests: ## Run the Python unit test suite
	$(PYTHON) -m pytest

dbt-parse: ## Parse the dbt project without executing data tests
	$(DBT_ENV) $(DBT) parse --profiles-dir $(PROFILES_DIR)

pip-check: ## Verify installed Python dependency consistency
	$(PIP) check

test: ## Run Python tests and dbt parse (not dbt data tests)
	$(MAKE) python-tests
	$(MAKE) dbt-parse

lint: ## Run Ruff and SQLFluff static checks
	.venv/bin/ruff check src tests
	.venv/bin/sqlfluff lint models macros

format: ## Format Python sources and apply safe Ruff fixes
	.venv/bin/ruff format src tests
	.venv/bin/ruff check --fix src tests

full-validate: ## Run static, unit, parse, and bounded data validation
	$(MAKE) pip-check
	$(MAKE) test
	$(MAKE) lint
	$(MAKE) data-tests

pipeline-resume: ## Resume the existing database without rerunning immutable completed stages
	EPC_V5_DUCKDB_PATH="$(DB_PATH)" EPC_V5_MEMORY_LIMIT="$(MEMORY_LIMIT)" \
		EPC_V5_MAX_TEMP_SIZE="$(MAX_TEMP_SIZE)" EPC_V5_DBT_THREADS="$(DBT_THREADS)" \
		EPC_V5_DUCKDB_THREADS="$(DUCKDB_THREADS)" \
		EPC_V5_SPLINK_TEMP_DIR="$(SPLINK_TEMP_DIR)" \
		EPC_V5_CALIBRATION_TEMP_DIR="$(CALIBRATION_TEMP_DIR)" \
		./bin/run_pipeline.sh resume

pipeline-clean-build: ## Build a new database; refuses to overwrite DB_PATH
	EPC_V5_DUCKDB_PATH="$(DB_PATH)" EPC_V5_MEMORY_LIMIT="$(MEMORY_LIMIT)" \
		EPC_V5_MAX_TEMP_SIZE="$(MAX_TEMP_SIZE)" EPC_V5_DBT_THREADS="$(DBT_THREADS)" \
		EPC_V5_DUCKDB_THREADS="$(DUCKDB_THREADS)" \
		EPC_V5_SPLINK_TEMP_DIR="$(SPLINK_TEMP_DIR)" \
		EPC_V5_CALIBRATION_TEMP_DIR="$(CALIBRATION_TEMP_DIR)" \
		./bin/run_pipeline.sh clean-build

splink-scratch-inventory: ## Read-only inventory of non-authoritative Splink scratch tables
	./bin/splink-scratch-inventory "$(DB_PATH)"

clean: ## Remove dbt-generated target/package directories only
	$(DBT) clean --profiles-dir $(PROFILES_DIR)

ui: ## Start DuckDB UI for the project database on the remote machine
	DUCKDB_UI_PORT=$(DUCKDB_UI_PORT) ./bin/duckdb-ui-epc "$(CURDIR)/$(DB_PATH)"

ui-ssh: ## Print the SSH tunnel command to run on your laptop
	DUCKDB_UI_PORT=$(DUCKDB_UI_PORT) ./bin/duckdb-ui-ssh $(DUCKDB_UI_PORT)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-27s\033[0m %s\n", $$1, $$2}'
