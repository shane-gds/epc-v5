{{ config(materialized='view', tags=['identity', 'decision']) }}

with current_scores as (
    select score.*
    from {{ source('identity_scoring', 'identity_match_score') }} as score
    inner join {{ ref('int_identity_current_run') }} as current_run
        on score.identity_run_key = current_run.identity_run_key
),

endpoint_alternatives as (
    select
        candidate.identity_run_id,
        candidate.identity_run_key,
        candidate.run_observation_key_l as identity_run_observation_key,
        candidate.run_observation_key_r as counterpart_run_observation_key,
        candidate.candidate_pair_key,
        score.match_score_key,
        score.match_weight,
        score.match_probability
    from {{ ref('identity_candidate_pair') }} as candidate
    inner join current_scores as score
        on candidate.candidate_pair_key = score.candidate_pair_key

    union all

    select
        candidate.identity_run_id,
        candidate.identity_run_key,
        candidate.run_observation_key_r,
        candidate.run_observation_key_l,
        candidate.candidate_pair_key,
        score.match_score_key,
        score.match_weight,
        score.match_probability
    from {{ ref('identity_candidate_pair') }} as candidate
    inner join current_scores as score
        on candidate.candidate_pair_key = score.candidate_pair_key
)

select
    *,
    'OBSERVATION_ENDPOINT_ONLY_UNCALIBRATED' as competition_scope,
    row_number() over (
        partition by identity_run_key, identity_run_observation_key
        order by match_weight desc, candidate_pair_key asc
    ) as alternative_rank,
    match_weight - lead(match_weight) over (
        partition by identity_run_key, identity_run_observation_key
        order by match_weight desc, candidate_pair_key asc
    ) as margin_to_next_observation
from endpoint_alternatives
