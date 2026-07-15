{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='identity_run_key',
    tags=['identity', 'intermediate']
) }}

select
    current_identity_run.identity_run_id,
    current_identity_run.identity_run_key,
    current_identity_run.population_fingerprint,
    current_identity_run.input_source_file_count,
    current_identity_run.input_release_keys,
    current_identity_run.algorithm_version,
    current_identity_run.normaliser_version,
    current_identity_run.eligibility_contract_version,
    current_identity_run.calculated_at as registered_at
from {{ ref('int_identity_current_run') }} as current_identity_run
{% if is_incremental() %}
    where not exists (
        select 1
        from {{ this }} as existing_run
        where existing_run.identity_run_key = current_identity_run.identity_run_key
    )
{% endif %}
