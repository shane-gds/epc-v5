with expected as (
    select count(*) as expected_count
    from {{ ref('stg_pp_transaction_observation') }}
    union all
    select count(*)
    from {{ ref('stg_epc_certificate_observation') }}
),

actual as (
    select count(*) as actual_count
    from {{ ref('int_identity_observation') }} as observation
    where observation.identity_run_key = (
        select current_run.identity_run_key
        from {{ ref('int_identity_current_run') }} as current_run
    )
)

select
    sum(expected.expected_count) as expected_count,
    max(actual.actual_count) as actual_count
from expected
cross join actual
having sum(expected.expected_count) <> max(actual.actual_count)
