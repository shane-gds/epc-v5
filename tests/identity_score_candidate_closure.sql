with current_run as (
    select identity_run_key
    from {{ ref('int_identity_current_run') }}
),

current_candidates as (
select candidate_pair_key
from {{ ref('identity_candidate_pair') }}
inner join current_run using (identity_run_key)
),

current_scores as (
select candidate_pair_key
from {{ ref('identity_current_match_score') }}
)

select
'CANDIDATE_WITHOUT_SCORE' as issue_type,
candidate.candidate_pair_key
from current_candidates as candidate
left join current_scores as score on candidate.candidate_pair_key = score.candidate_pair_key
where score.candidate_pair_key is null

union all

select
'SCORE_WITHOUT_CANDIDATE',
score.candidate_pair_key
from current_scores as score
left join current_candidates as candidate on score.candidate_pair_key = candidate.candidate_pair_key
where candidate.candidate_pair_key is null
