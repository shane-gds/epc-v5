select
    assignment.assignment_key,
    assignment.identity_run_key as assignment_run_key,
    observation.identity_run_key as observation_run_key,
    assignment.source_record_key as assignment_source_record_key,
    observation.source_record_key as observation_source_record_key,
    assignment.source_dataset as assignment_source_dataset,
    observation.source_dataset as observation_source_dataset
from {{ ref('bridge_source_record_entity_assignment') }} as assignment
left join {{ ref('int_identity_observation') }} as observation
    on assignment.identity_run_observation_key = observation.identity_run_observation_key
where
    observation.identity_run_observation_key is null
    or assignment.identity_run_key is distinct from observation.identity_run_key
    or assignment.source_record_key is distinct from observation.source_record_key
    or assignment.source_dataset is distinct from observation.source_dataset
    or assignment.identity_observation_key is distinct from observation.identity_observation_key
