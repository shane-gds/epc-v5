with eligible as (
    select identity_run_observation_key
    from {{ ref('int_identity_observation') }} as observation
    inner join {{ ref('int_identity_current_run') }} as current_run
        on observation.identity_run_key = current_run.identity_run_key
    where observation.is_identity_eligible
),

hypotheses as (
    select identity_run_observation_key
    from {{ ref('identity_hypothesis') }} as hypothesis
    inner join {{ ref('int_identity_current_run') }} as current_run
        on hypothesis.identity_run_key = current_run.identity_run_key
)

select
    'ELIGIBLE_WITHOUT_HYPOTHESIS' as issue_type,
    eligible.identity_run_observation_key
from eligible
left join
    hypotheses
    on eligible.identity_run_observation_key = hypotheses.identity_run_observation_key
where hypotheses.identity_run_observation_key is null

union all

select
'HYPOTHESIS_WITHOUT_ELIGIBLE',
hypotheses.identity_run_observation_key
from hypotheses
left join
eligible
on hypotheses.identity_run_observation_key = eligible.identity_run_observation_key
where eligible.identity_run_observation_key is null
