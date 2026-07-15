with profile as (
    select
        certificate_number,
        count(*) as observation_count,
        count(*) filter (where certificate_conflict_status = 'UNIQUE') as unique_count,
        count(*) filter (
            where certificate_conflict_status in ('EXACT_DUPLICATE', 'CONFLICT')
        ) as duplicate_status_count
    from {{ ref('stg_epc_certificate_observation') }}
    group by certificate_number
)

select *
from profile
where
    (observation_count = 1 and unique_count <> 1)
    or (observation_count > 1 and duplicate_status_count <> observation_count)
