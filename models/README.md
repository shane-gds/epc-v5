# dbt model layers

The authoritative contracts are in `../docs/epc-v5-data-model-design.md`.

Build models in narrative/DAG order. A layer may consume its upstream layers, but must not silently recreate identity, currentness, policy or geography logic that already has an authoritative model.
