{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='match_decision_key',
    on_schema_change='append_new_columns',
    tags=['identity', 'decision']
) }}

with current_run as (
    select
        identity_run_id,
        identity_run_key,
        decision_policy_version
    from {{ ref('int_identity_current_run') }}
),

scores as (
    select score.*
    from {{ ref('identity_current_match_score') }} as score
),

decisions as (
    select
        {{ stable_sha256(
            'epc-v4.identity.match-decision',
            'v1',
            ['score.match_score_key', 'current_run.decision_policy_version']
        ) }} as match_decision_key,
        score.match_score_key,
        score.candidate_pair_key,
        score.identity_run_id,
        score.identity_run_key,
        score.splink_run_id,
        score.model_version,
        score.model_sha256,
        current_run.decision_policy_version,
        'REVIEW' as decision_outcome,
        case
            when
                score.primary_blocking_rule_code = 'D01_EXACT_UPRN'
                and (
                    score.premise_address_comparison_level <> 'EXACT'
                    or score.postcode_comparison_level <> 'EXACT'
                ) then 'UNCALIBRATED_DIRECT_IDENTIFIER_HETEROGENEOUS'
            when score.primary_blocking_rule_code = 'D01_EXACT_UPRN'
                then 'UNCALIBRATED_DIRECT_IDENTIFIER_CONSISTENT'
            else 'UNCALIBRATED_PROBABILISTIC_MODEL'
        end as decision_reason,
        case
            when
                score.primary_blocking_rule_code = 'D01_EXACT_UPRN'
                and (
                    score.premise_address_comparison_level <> 'EXACT'
                    or score.postcode_comparison_level <> 'EXACT'
                ) then 'HIGH'
            when score.primary_blocking_rule_code = 'P02_SECTOR_PREMISE_EXACT' then 'MEDIUM'
            else 'STANDARD'
        end as review_priority,
        false as is_accepted_edge,
        score.match_weight,
        score.match_probability,
        current_timestamp as decided_at
    from scores as score
    cross join current_run
)

select *
from decisions
{% if is_incremental() %}
    where not exists (
        select 1
        from {{ this }} as existing_decision
        where existing_decision.match_decision_key = decisions.match_decision_key
    )
{% endif %}
