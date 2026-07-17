with current_candidates as (
    select candidate_pair_key
    from {{ ref('identity_candidate_pair') }} as candidate
    inner join {{ ref('int_identity_current_run') }} as current_run
        on candidate.identity_run_key = current_run.identity_run_key
),

current_decisions as (
    select candidate_pair_key
    from {{ ref('identity_current_match_decision') }} as decision
    inner join {{ ref('int_identity_current_run') }} as current_run
        on decision.identity_run_key = current_run.identity_run_key
)

select
    'CANDIDATE_WITHOUT_DECISION' as issue_type,
    candidate.candidate_pair_key
from current_candidates as candidate
left join
    current_decisions as decision
    on candidate.candidate_pair_key = decision.candidate_pair_key
where decision.candidate_pair_key is null

union all

select
'DECISION_WITHOUT_CANDIDATE',
decision.candidate_pair_key
from current_decisions as decision
left join
current_candidates as candidate
on decision.candidate_pair_key = candidate.candidate_pair_key
where candidate.candidate_pair_key is null
