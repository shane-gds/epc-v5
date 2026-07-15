with allocation_count as (
    select coalesce(sum(source_record_count), 0) as expected_count
    from {{ ref('stg_onsud_uprn_allocation') }}
),

bridge_count as (
    select count(*) as actual_count
    from {{ ref('bridge_onsud_allocation_source_record') }}
)

select
    allocation.expected_count,
    bridge.actual_count
from allocation_count as allocation
cross join bridge_count as bridge
where allocation.expected_count <> bridge.actual_count
