-- noqa: disable=AL03
with fixtures as (
    select
        'UNIQUE' as certificate_number,
        '1 HIGH ST' as address,
        '50' as floor_area
    union all
    select
        'EXACT',
        '2 HIGH ST',
        '60'
    union all
    select
        'EXACT',
        '2 HIGH ST',
        '60'
    union all
    select
        'CONFLICT',
        '3 HIGH ST',
        '70'
    union all
    select
        'CONFLICT',
        '3 HIGH ST',
        '71'
),

keyed as (
    select
        *,
        {{ stable_sha256(
            'epc-v4.test.epc-payload',
            'v1',
            ['address', 'floor_area']
        ) }} as payload_hash
    from fixtures
),

classified as (
    select
        certificate_number,
        case
            when count(*) = 1 then 'UNIQUE'
            when count(distinct payload_hash) = 1 then 'EXACT_DUPLICATE'
            else 'CONFLICT'
        end as actual_status
    from keyed
    group by certificate_number
),

expected as (
    select
        'UNIQUE' as certificate_number,
        'UNIQUE' as expected_status
    union all
    select
        'EXACT',
        'EXACT_DUPLICATE'
    union all
    select
        'CONFLICT',
        'CONFLICT'
)

select classified.*
from classified
inner join expected on classified.certificate_number = expected.certificate_number
where classified.actual_status <> expected.expected_status
