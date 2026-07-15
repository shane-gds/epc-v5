with profile as (
    select
        dataset_release_id,
        uprn,
        count(*) as allocation_count,
        max(distinct_allocation_count) as declared_allocation_count,
        count(*) filter (where allocation_status = 'CONFLICT') as conflict_count
    from {{ ref('stg_onsud_uprn_allocation') }}
    group by dataset_release_id, uprn
)

select *
from profile
where
    allocation_count <> declared_allocation_count
    or (allocation_count > 1 and conflict_count <> allocation_count)
