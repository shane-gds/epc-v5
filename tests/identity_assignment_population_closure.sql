with eligible as (
    select
        count(*) as observation_count,
        bit_xor(hash(observation.identity_run_observation_key)) as endpoint_checksum,
        bit_xor(hash(observation.source_record_key)) as source_record_checksum
    from {{ ref('int_identity_observation') }} as observation
    inner join {{ ref('int_identity_current_run') }} as current_run
        on observation.identity_run_key = current_run.identity_run_key
    where observation.is_identity_eligible
),

assignments as (
    select
        count(*) as observation_count,
        bit_xor(hash(assignment.identity_run_observation_key)) as endpoint_checksum,
        bit_xor(hash(assignment.source_record_key)) as source_record_checksum
    from {{ ref('bridge_source_record_entity_assignment') }} as assignment
    inner join {{ ref('int_identity_current_run') }} as current_run
        on assignment.identity_run_key = current_run.identity_run_key
    where assignment.is_current
)

select
    eligible.observation_count as expected_observation_count,
    assignments.observation_count as actual_assignment_count,
    eligible.endpoint_checksum as expected_endpoint_checksum,
    assignments.endpoint_checksum as actual_endpoint_checksum,
    eligible.source_record_checksum as expected_source_record_checksum,
    assignments.source_record_checksum as actual_source_record_checksum
from eligible
cross join assignments
where
    eligible.observation_count <> assignments.observation_count
    or eligible.endpoint_checksum <> assignments.endpoint_checksum
    or eligible.source_record_checksum <> assignments.source_record_checksum
