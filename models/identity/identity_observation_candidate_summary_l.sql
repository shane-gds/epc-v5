{{ config(materialized='table', tags=['identity', 'decision']) }}

select
    candidate.identity_run_id,
    candidate.identity_run_key,
    candidate.run_observation_key_l as identity_run_observation_key,
    count(*) as candidate_count,
    count(*) filter (where decision.decision_outcome = 'REVIEW') as review_candidate_count,
    max(decision.match_weight) as top_match_weight,
    arg_max(
        candidate.candidate_pair_key,
        struct_pack(weight := decision.match_weight, candidate := candidate.candidate_pair_key)
    ) as top_candidate_pair_key,
    arg_max(
        candidate.run_observation_key_r,
        struct_pack(weight := decision.match_weight, candidate := candidate.candidate_pair_key)
    ) as top_counterpart_run_observation_key
from {{ ref('identity_candidate_pair') }} as candidate
inner join {{ ref('identity_match_decision') }} as decision
    on candidate.candidate_pair_key = decision.candidate_pair_key
inner join {{ ref('int_identity_current_run') }} as current_run
    on candidate.identity_run_key = current_run.identity_run_key
group by
    candidate.identity_run_id, candidate.identity_run_key,
    candidate.run_observation_key_l
