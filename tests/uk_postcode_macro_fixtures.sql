-- noqa: disable=AL03
with fixtures as (
    select
        'S4 8GG' as raw_postcode,
        'S4 8GG' as expected_postcode,
        'S4 8' as expected_sector
    union all
    select
        ' sw1a 1aa ',
        'SW1A 1AA',
        'SW1A 1'
    union all
    select
        'UNKNOWN',
        null,
        null
),

evaluated as (
    select
        *,
        {{ normalise_uk_postcode('raw_postcode') }} as actual_postcode,
        {{ uk_postcode_sector('raw_postcode') }} as actual_sector
    from fixtures
)

select *
from evaluated
where
    actual_postcode is distinct from expected_postcode
    or actual_sector is distinct from expected_sector
