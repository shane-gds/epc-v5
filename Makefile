SHELL := /usr/bin/bash
PYTHON := .venv/bin/python
PIP := .venv/bin/pip
DBT := .venv/bin/dbt

.PHONY: setup install dbt-deps debug test lint format clean

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

clean:
	$(DBT) clean --profiles-dir .
