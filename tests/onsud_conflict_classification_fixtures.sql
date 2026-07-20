-- noqa: disable=AL03
with fixtures as (
    select
        'release' as release_key,
        1 as uprn,
        'S4 8GG' as postcode,
        100 as easting
    union all
    select
        'release',
        2,
        'S4 8GH',
        200
    union all
    select
        'release',
        2,
        'S4 8GH',
        200
    union all
    select
        'release',
        3,
        'S4 8GJ',
        300
    union all
    select
        'release',
        3,
        'S4 8GJ',
        301
),

keyed as (
    select
        *,
        {{ stable_sha256(
            'epc-v5.test.onsud-allocation',
            'v1',
            ['release_key', 'cast(uprn as varchar)', 'postcode', 'cast(easting as varchar)']
        ) }} as allocation_key
    from fixtures
),

allocation_tuple as (
    select
        release_key,
        uprn,
        allocation_key,
        count(*) as source_record_count
    from keyed
    group by release_key, uprn, allocation_key
),

classified as (
    select
        allocation.uprn,
        case
            when count(*) over (partition by allocation.release_key, allocation.uprn) > 1
                then 'CONFLICT'
            when allocation.source_record_count > 1 then 'EXACT_DUPLICATE'
            else 'UNIQUE'
        end as actual_status
    from allocation_tuple as allocation
),

expected as (
    select
        1 as uprn,
        'UNIQUE' as expected_status
    union all
    select
        2,
        'EXACT_DUPLICATE'
    union all
    select
        3,
        'CONFLICT'
)

select classified.*
from classified
inner join expected on classified.uprn = expected.uprn
where classified.actual_status <> expected.expected_status
