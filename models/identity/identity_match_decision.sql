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

current_splink_run as (
    select
        splink_run.splink_run_id,
        splink_run.identity_run_key,
        splink_run.model_sha256
    from {{ source('identity_scoring', 'identity_splink_run') }} as splink_run
    inner join current_run
        on splink_run.identity_run_key = current_run.identity_run_key
    where
        splink_run.run_mode = 'NATIONAL'
        and splink_run.run_status = 'SUCCEEDED'
    qualify row_number() over (order by splink_run.completed_at desc) = 1
),

scores as (
    select score.*
    from {{ source('identity_scoring', 'identity_match_score') }} as score
    inner join current_splink_run
        on score.splink_run_id = current_splink_run.splink_run_id
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
