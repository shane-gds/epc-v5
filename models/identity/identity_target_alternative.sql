{{ config(materialized='table', tags=['identity', 'calibration']) }}

select
    {{ stable_sha256(
        'epc-v4.identity.target-alternative',
        'v1',
        [
            'coalesce(left_alternative.identity_run_key, right_alternative.identity_run_key)',
            'coalesce(left_alternative.identity_run_observation_key, right_alternative.identity_run_observation_key)',
            'coalesce(left_alternative.target_hypothesis_key, right_alternative.target_hypothesis_key)'
        ]
    ) }} as target_alternative_key,
    coalesce(left_alternative.identity_run_id, right_alternative.identity_run_id)
        as identity_run_id,
    coalesce(left_alternative.identity_run_key, right_alternative.identity_run_key)
        as identity_run_key,
    coalesce(
        left_alternative.identity_run_observation_key,
        right_alternative.identity_run_observation_key
    ) as identity_run_observation_key,
    coalesce(
        left_alternative.target_hypothesis_key,
        right_alternative.target_hypothesis_key
    ) as target_hypothesis_key,
    coalesce(
        left_alternative.target_hypothesis_type,
        right_alternative.target_hypothesis_type
    ) as target_hypothesis_type,
    coalesce(left_alternative.supporting_candidate_count, 0)
    + coalesce(right_alternative.supporting_candidate_count, 0)
        as supporting_candidate_count,
    coalesce(left_alternative.counterpart_observation_count, 0)
    + coalesce(right_alternative.counterpart_observation_count, 0)
        as counterpart_observation_count,
    least(
        left_alternative.first_counterpart_event_date,
        right_alternative.first_counterpart_event_date
    ) as first_counterpart_event_date,
    greatest(
        left_alternative.last_counterpart_event_date,
        right_alternative.last_counterpart_event_date
    ) as last_counterpart_event_date,
    greatest(left_alternative.top_match_weight, right_alternative.top_match_weight)
        as top_match_weight,
    greatest(left_alternative.top_match_probability, right_alternative.top_match_probability)
        as top_match_probability,
    case
        when left_alternative.top_match_weight is null
            then right_alternative.top_candidate_pair_key
        when right_alternative.top_match_weight is null
            then left_alternative.top_candidate_pair_key
        when left_alternative.top_match_weight > right_alternative.top_match_weight
            then left_alternative.top_candidate_pair_key
        when right_alternative.top_match_weight > left_alternative.top_match_weight
            then right_alternative.top_candidate_pair_key
        else least(
            left_alternative.top_candidate_pair_key,
            right_alternative.top_candidate_pair_key
        )
    end as top_candidate_pair_key,
    case
        when left_alternative.top_match_weight is null
            then right_alternative.top_counterpart_run_observation_key
        when right_alternative.top_match_weight is null
            then left_alternative.top_counterpart_run_observation_key
        when left_alternative.top_match_weight > right_alternative.top_match_weight
            then left_alternative.top_counterpart_run_observation_key
        when right_alternative.top_match_weight > left_alternative.top_match_weight
            then right_alternative.top_counterpart_run_observation_key
        when left_alternative.top_candidate_pair_key <= right_alternative.top_candidate_pair_key
            then left_alternative.top_counterpart_run_observation_key
        else right_alternative.top_counterpart_run_observation_key
    end as top_counterpart_run_observation_key,
    current_timestamp as grouped_at
from {{ ref('identity_target_alternative_l') }} as left_alternative
full outer join {{ ref('identity_target_alternative_r') }} as right_alternative
    on
        left_alternative.identity_run_key = right_alternative.identity_run_key
        and left_alternative.identity_run_observation_key
        = right_alternative.identity_run_observation_key
        and left_alternative.target_hypothesis_key
        = right_alternative.target_hypothesis_key
