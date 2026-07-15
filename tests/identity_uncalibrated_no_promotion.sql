select
    'ACCEPTED_EDGE' as issue_type,
    candidate_pair_key as evidence_key
from {{ ref('identity_match_decision') }}
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
