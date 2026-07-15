with expected as (
    select 'SALE' as fact_name, count(*) as expected_count
    from {{ ref('stg_pp_transaction_observation') }}
    union all
    select 'EPC', count(distinct concat(cast(dataset_release_id as varchar), certificate_number))
    from {{ ref('stg_epc_certificate_observation') }}
    union all
    select 'RECOMMENDATION', count(*)
    from {{ ref('stg_epc_recommendation_observation') }}
),

actual as (
    select 'SALE' as fact_name, count(*) as actual_count
    from {{ ref('fct_sale_transaction') }}
    union all
    select 'EPC', count(*)
    from {{ ref('fct_epc_certificate') }}
    union all
    select 'RECOMMENDATION', count(*)
    from {{ ref('fct_epc_recommendation_observation') }}
)

select expected.fact_name, expected.expected_count, actual.actual_count
from expected
inner join actual on expected.fact_name = actual.fact_name
where expected.expected_count <> actual.actual_count
