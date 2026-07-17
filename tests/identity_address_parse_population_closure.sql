with current_run as (
    select *
    from {{ ref('int_identity_current_run') }}
),

outcomes as (
    select
        request.address_parse_run_key,
        count(*) as request_count,
        count(result.address_parse_result_key) as outcome_count,
        count(*) filter (where result.parse_status = 'ERROR') as error_count
    from {{ source('identity_address_parser', 'identity_address_parse_request') }} as request
    left join {{ source('identity_address_parser', 'identity_address_parse_result') }} as result
        on request.address_parse_result_key = result.address_parse_result_key
    inner join current_run
        on request.address_parse_run_key = current_run.address_parse_run_key
    group by request.address_parse_run_key
)

select current_run.address_parse_run_key
from current_run
left join outcomes
    on current_run.address_parse_run_key = outcomes.address_parse_run_key
where
    coalesce(outcomes.request_count, 0) <> current_run.routed_address_count
    or coalesce(outcomes.outcome_count, 0) <> current_run.routed_address_count
    or coalesce(outcomes.error_count, 0) <> 0
