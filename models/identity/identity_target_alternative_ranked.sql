{{ config(materialized='table', tags=['identity', 'calibration']) }}

select
    *,
    'TARGET_HYPOTHESIS_UNCALIBRATED' as competition_scope,
    row_number() over (
        partition by identity_run_key, identity_run_observation_key
        order by top_match_weight desc, target_hypothesis_key asc
    ) as target_alternative_rank,
    count(*) over (
        partition by identity_run_key, identity_run_observation_key
    ) as target_alternative_count,
    top_match_weight - lead(top_match_weight) over (
        partition by identity_run_key, identity_run_observation_key
        order by top_match_weight desc, target_hypothesis_key asc
    ) as margin_to_next_target
from {{ ref('identity_target_alternative') }}
