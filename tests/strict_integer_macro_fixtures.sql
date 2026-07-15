-- noqa: disable=AL03
with fixtures as (
    select
        '001' as raw_value,
        cast(1 as ubigint) as expected_unsigned
    union all
    select
        ' 42 ',
        cast(42 as ubigint)
    union all
    select
        '1.5',
        null
    union all
    select
        '1e3',
        null
    union all
    select
        '-1',
        null
    union all
    select
        '18446744073709551616',
        null
),

evaluated as (
    select
        *,
        {{ try_strict_unsigned_integer('raw_value', 'ubigint') }} as actual_unsigned
    from fixtures
)

select *
from evaluated
where actual_unsigned is distinct from expected_unsigned
