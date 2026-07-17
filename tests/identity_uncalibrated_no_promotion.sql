select
    'ACCEPTED_EDGE' as issue_type,
    candidate_pair_key as evidence_key
from {{ ref('identity_current_match_decision') }}
where is_accepted_edge

union all

select
    'REGISTRY_ENTITY',
    cast(registry_entity_id as varchar)
from {{ source('registry_foundation', 'registry_entity') }}

union all

select
    'REGISTRY_IDENTIFIER',
    cast(registry_identifier_id as varchar)
from {{ source('registry_foundation', 'registry_identifier') }}

union all

select
    'REGISTRY_OBSERVATION',
    cast(registry_entity_id as varchar)
from {{ source('registry_foundation', 'bridge_registry_observation') }}

union all

select
    'RESOLVED_ASSIGNMENT',
    assignment_key
from {{ ref('bridge_source_record_entity_assignment') }}
where
    assignment_status <> 'UNRESOLVED'
    or registry_entity_id is not null
    or assignment_confidence is not null
