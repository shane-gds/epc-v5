{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='candidate_pair_key',
    on_schema_change='append_new_columns',
    tags=['identity', 'candidate_generation']
) }}

with current_rule_hits as (
    select rule_hit.*
    from {{ ref('identity_candidate_rule_hit') }} as rule_hit
    inner join {{ ref('int_identity_current_run') }} as current_run
        on rule_hit.identity_run_key = current_run.identity_run_key
),

classified as (
    select
        candidate_pair_key,
        identity_run_id,
        identity_run_key,
        run_observation_key_l,
        run_observation_key_r,
        observation_key_l,
        observation_key_r,
        policy_version as blocking_policy_version,
        rule_code as primary_blocking_rule_code,
        rule_logic_version as primary_rule_logic_version,
        rule_priority as primary_rule_priority,
        1 as blocking_rule_count,
        evidence_class,
        true as requires_splink_score,
        'GENERATED' as candidate_status,
        generated_at,
        list_value(rule_code) as blocking_rule_codes
    from current_rule_hits
)

select *
from classified
{% if is_incremental() %}
    where not exists (
        select 1
        from {{ this }} as existing_pair
        where existing_pair.candidate_pair_key = classified.candidate_pair_key
    )
{% endif %}
