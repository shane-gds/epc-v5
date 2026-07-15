{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='identity_hypothesis_key',
    on_schema_change='append_new_columns',
    tags=['identity', 'decision', 'cluster']
) }}

with current_observations as (
    select observation.*
    from {{ ref('int_identity_observation') }} as observation
    inner join {{ ref('int_identity_current_run') }} as current_run
        on observation.identity_run_key = current_run.identity_run_key
    where observation.is_identity_eligible
),

hypotheses as (
    select
        {{ stable_sha256(
            'epc-v4.identity.hypothesis',
            'v1',
            ['observation.identity_run_key', 'observation.identity_run_observation_key']
        ) }} as identity_hypothesis_key,
        {{ stable_sha256(
            'epc-v4.identity.singleton-cluster',
            'v1',
            ['observation.identity_run_key', 'observation.identity_run_observation_key']
        ) }} as identity_cluster_key,
        observation.identity_run_id,
        observation.identity_run_key,
        observation.identity_run_observation_key,
        observation.identity_observation_key,
        case
            when candidate_summary.identity_run_observation_key is null
                then 'SINGLETON_NO_CANDIDATE'
            else 'UNRESOLVED_REVIEW'
        end as hypothesis_outcome,
        coalesce(candidate_summary.candidate_count, 0) as candidate_count,
        coalesce(candidate_summary.review_candidate_count, 0) as review_candidate_count,
        candidate_summary.top_candidate_pair_key,
        candidate_summary.top_counterpart_run_observation_key,
        candidate_summary.top_match_weight,
        'NOT_PROMOTED_UNCALIBRATED' as registry_promotion_status,
        current_timestamp as hypothesised_at
    from current_observations as observation
    left join {{ ref('identity_observation_candidate_summary') }} as candidate_summary
        on
            observation.identity_run_observation_key
            = candidate_summary.identity_run_observation_key
)

select *
from hypotheses
{% if is_incremental() %}
    where not exists (
        select 1
        from {{ this }} as existing_hypothesis
        where existing_hypothesis.identity_hypothesis_key = hypotheses.identity_hypothesis_key
    )
{% endif %}
