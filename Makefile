SHELL := /usr/bin/bash
PYTHON := .venv/bin/python
PIP := .venv/bin/pip
DBT := .venv/bin/dbt

DB_PATH ?= output/duckdb/epc_v4.duckdb
DUCKDB_UI_PORT ?= 4214

.PHONY: setup install dbt-deps debug test lint format clean ui ui-ssh help

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
