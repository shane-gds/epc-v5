{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='identity_run_key',
    on_schema_change='append_new_columns',
    tags=['identity', 'intermediate']
) }}

select
    current_identity_run.identity_run_id,
    current_identity_run.identity_run_key,
    current_identity_run.population_fingerprint,
    current_identity_run.input_source_file_count,
    current_identity_run.input_release_keys,
    current_identity_run.blocking_policy_fingerprint,
    current_identity_run.blocking_rule_count,
    current_identity_run.address_parse_run_id,
    current_identity_run.address_parse_run_key,
    current_identity_run.route_population_fingerprint,
    current_identity_run.selector_contract_version,
    current_identity_run.parser_input_contract_version,
    current_identity_run.parser_contract_version,
    current_identity_run.runtime_artifact_key,
    current_identity_run.parser_implementation_sha256,
    current_identity_run.routed_address_count,
    current_identity_run.algorithm_version,
    current_identity_run.normaliser_version,
    current_identity_run.eligibility_contract_version,
    current_identity_run.address_component_contract_version,
    current_identity_run.blocking_policy_version,
    current_identity_run.comparison_model_version,
    current_identity_run.decision_policy_version,
    current_identity_run.calculated_at as registered_at
from {{ ref('int_identity_current_run') }} as current_identity_run
{% if is_incremental() %}
    where not exists (
        select 1
        from {{ this }} as existing_run
        where existing_run.identity_run_key = current_identity_run.identity_run_key
    )
{% endif %}
