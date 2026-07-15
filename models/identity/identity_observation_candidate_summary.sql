{{ config(materialized='table', tags=['identity', 'decision']) }}

select
    coalesce(left_summary.identity_run_id, right_summary.identity_run_id) as identity_run_id,
    coalesce(left_summary.identity_run_key, right_summary.identity_run_key) as identity_run_key,
    coalesce(
        left_summary.identity_run_observation_key,
        right_summary.identity_run_observation_key
    ) as identity_run_observation_key,
    coalesce(left_summary.candidate_count, 0)
    + coalesce(right_summary.candidate_count, 0) as candidate_count,
    coalesce(left_summary.review_candidate_count, 0)
    + coalesce(right_summary.review_candidate_count, 0) as review_candidate_count,
    greatest(left_summary.top_match_weight, right_summary.top_match_weight)
        as top_match_weight,
    case
        when left_summary.top_match_weight is null then right_summary.top_candidate_pair_key
        when right_summary.top_match_weight is null then left_summary.top_candidate_pair_key
        when left_summary.top_match_weight > right_summary.top_match_weight
            then left_summary.top_candidate_pair_key
        when right_summary.top_match_weight > left_summary.top_match_weight
            then right_summary.top_candidate_pair_key
        else least(left_summary.top_candidate_pair_key, right_summary.top_candidate_pair_key)
    end as top_candidate_pair_key,
    case
        when left_summary.top_match_weight is null
            then right_summary.top_counterpart_run_observation_key
        when right_summary.top_match_weight is null
            then left_summary.top_counterpart_run_observation_key
        when left_summary.top_match_weight > right_summary.top_match_weight
            then left_summary.top_counterpart_run_observation_key
        when right_summary.top_match_weight > left_summary.top_match_weight
            then right_summary.top_counterpart_run_observation_key
        when left_summary.top_candidate_pair_key <= right_summary.top_candidate_pair_key
            then left_summary.top_counterpart_run_observation_key
        else right_summary.top_counterpart_run_observation_key
    end as top_counterpart_run_observation_key,
    current_timestamp as summarised_at
from {{ ref('identity_observation_candidate_summary_l') }} as left_summary
full outer join {{ ref('identity_observation_candidate_summary_r') }} as right_summary
    on
        left_summary.identity_run_key = right_summary.identity_run_key
        and left_summary.identity_run_observation_key
        = right_summary.identity_run_observation_key
