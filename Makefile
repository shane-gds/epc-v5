SHELL := /usr/bin/bash
PYTHON := .venv/bin/python
PIP := .venv/bin/pip
DBT := .venv/bin/dbt

DB_PATH ?= output/duckdb/epc_v5.duckdb
DUCKDB_UI_PORT ?= 4214
LIBPOSTAL_SAMPLE_SIZE ?= 10000
LIBPOSTAL_BATCH_SIZE ?= 5000

.PHONY: setup install dbt-deps debug test lint format clean ui ui-ssh help libpostal-setup libpostal-benchmark libpostal-parse identity-candidates

setup:
	python3.12 -m venv .venv
	$(PIP) install --upgrade pip setuptools wheel
	$(PIP) install -e ".[dev,graph,parquet]"
	$(DBT) deps --profiles-dir .

install:
	$(PIP) install -e ".[dev,graph,parquet]"
	$(DBT) deps --profiles-dir .

dbt-deps:
	$(DBT) deps --profiles-dir .

debug:
	$(DBT) debug --profiles-dir .

test:
	$(PYTHON) -m pytest
	$(DBT) parse --profiles-dir .

lint:
	.venv/bin/ruff check src tests
	.venv/bin/sqlfluff lint models macros

format:
	.venv/bin/ruff format src tests
	.venv/bin/ruff check --fix src tests

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

clean:
	$(DBT) clean --profiles-dir .

ui: ## Start DuckDB UI for the project database on the remote machine
	DUCKDB_UI_PORT=$(DUCKDB_UI_PORT) ./bin/duckdb-ui-epc $(CURDIR)/$(DB_PATH)

ui-ssh: ## Print the SSH tunnel command to run on your laptop
	DUCKDB_UI_PORT=$(DUCKDB_UI_PORT) ./bin/duckdb-ui-ssh $(DUCKDB_UI_PORT)

libpostal-setup: ## Build the pinned native libpostal runtime
	./scripts/setup_libpostal_benchmark.sh

libpostal-benchmark: ## Run the shadow EPC/PPD libpostal benchmark
	$(PYTHON) -m epc_v5.benchmark_libpostal --database $(DB_PATH) \
		--sample-size $(LIBPOSTAL_SAMPLE_SIZE)

libpostal-parse: ## Select and parse only current flat-trap EPC addresses
	EPC_V5_DUCKDB_PATH=$(DB_PATH) $(DBT) run --profiles-dir . --select \
		int_epc_address_libpostal_route int_epc_address_libpostal_route_manifest
	$(PYTHON) -m epc_v5 parse-identity-addresses --database $(DB_PATH) --batch-size $(LIBPOSTAL_BATCH_SIZE)

identity-candidates: libpostal-parse ## Build current identity inputs and strict candidates
	EPC_V5_DUCKDB_PATH=$(DB_PATH) $(DBT) seed --profiles-dir . \
		--select identity_blocking_policy
	EPC_V5_DUCKDB_PATH=$(DB_PATH) $(DBT) run --profiles-dir . --select \
		int_identity_current_run identity_run_manifest int_identity_address_parse \
		int_identity_observation identity_libpostal_candidate_block_profile \
		identity_scoring_input identity_candidate_rule_hit identity_candidate_pair \
		identity_candidate_generation_audit
	EPC_V5_DUCKDB_PATH=$(DB_PATH) $(DBT) test --indirect-selection cautious \
		--profiles-dir . --select \
		int_epc_address_libpostal_route int_epc_address_libpostal_route_manifest \
		int_identity_address_parse int_identity_observation \
		identity_libpostal_candidate_block_profile identity_candidate_rule_hit \
		identity_candidate_pair reconcile_identity_observation_population \
		epc_address_libpostal_route_contract identity_address_parse_population_closure \
		identity_libpostal_candidate_block_limits \
		identity_libpostal_candidate_rule_contract identity_candidate_enabled_rules_only \
		identity_candidate_endpoint_closure identity_candidate_pair_closure \
		identity_candidate_rules_mutually_exclusive
