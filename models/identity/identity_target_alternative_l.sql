{{ config(materialized='table', tags=['identity', 'calibration']) }}

select
    candidate.identity_run_id,
    candidate.identity_run_key,
    candidate.run_observation_key_l as identity_run_observation_key,
    counterpart.target_hypothesis_key,
    counterpart.target_hypothesis_type,
    count(*) as supporting_candidate_count,
    count(*) as counterpart_observation_count,
    min(counterpart.event_date) as first_counterpart_event_date,
    max(counterpart.event_date) as last_counterpart_event_date,
    max(score.match_weight) as top_match_weight,
    max(score.match_probability) as top_match_probability,
    arg_max(candidate.candidate_pair_key, score.match_weight) as top_candidate_pair_key,
    arg_max(candidate.run_observation_key_r, score.match_weight)
        as top_counterpart_run_observation_key
from {{ ref('identity_candidate_pair') }} as candidate
inner join {{ ref('identity_current_match_score') }} as score
    on candidate.candidate_pair_key = score.candidate_pair_key
inner join {{ ref('identity_target_hypothesis') }} as counterpart
    on candidate.run_observation_key_r = counterpart.identity_run_observation_key
inner join {{ ref('int_identity_current_run') }} as current_run
    on candidate.identity_run_key = current_run.identity_run_key
group by
    candidate.identity_run_id, candidate.identity_run_key,
    candidate.run_observation_key_l, counterpart.target_hypothesis_key,
    counterpart.target_hypothesis_type
