with invalid_interval as (
    select assignment_key
    from {{ ref('bridge_source_record_entity_assignment') }}
    where
        valid_from is null
        or (is_current and valid_to is not null)
        or (not is_current and (valid_to is null or valid_to <= valid_from))
),

multiple_current as (
    select source_record_key
    from {{ ref('bridge_source_record_entity_assignment') }}
    where is_current
    group by source_record_key
    having count(*) > 1
)

select 'INVALID_INTERVAL' as issue_type, assignment_key as evidence_key
from invalid_interval
union all
select 'MULTIPLE_CURRENT', source_record_key
from multiple_current
