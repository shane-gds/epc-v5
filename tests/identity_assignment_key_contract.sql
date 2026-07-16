select
    assignment_key,
    identity_run_key,
    source_record_key,
    entity_hypothesis_key,
    assignment_status,
    assignment_method
from {{ ref('bridge_source_record_entity_assignment') }}
where assignment_key is distinct from {{ stable_sha256(
    'epc-v4.identity.source-record-assignment',
    'v1',
    [
        'identity_run_key',
        'source_record_key',
        'entity_hypothesis_key',
        'assignment_status',
        'assignment_method'
    ]
) }}
