select
    assignment.assignment_key,
    assignment.identity_run_key as assignment_run_key,
    hypothesis.identity_run_key as hypothesis_run_key,
    assignment.identity_run_observation_key as assignment_run_observation_key,
    hypothesis.identity_run_observation_key as hypothesis_run_observation_key
from {{ ref('bridge_source_record_entity_assignment') }} as assignment
left join {{ ref('identity_hypothesis') }} as hypothesis
    on assignment.entity_hypothesis_key = hypothesis.identity_hypothesis_key
where
    hypothesis.identity_hypothesis_key is null
    or assignment.identity_run_key is distinct from hypothesis.identity_run_key
    or assignment.identity_run_observation_key
        is distinct from hypothesis.identity_run_observation_key
