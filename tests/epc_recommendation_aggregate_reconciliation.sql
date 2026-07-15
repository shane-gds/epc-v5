with facts as (
    select
        count(*) as recommendation_count,
        count(*) filter (where epc_certificate_key is null) as orphan_count,
        count(*) filter (where epc_certificate_key is not null) as parented_count
    from {{ ref('fct_epc_recommendation_observation') }}
),

aggregates as (
    select
        count(*) as certificate_count,
        sum(recommendation_count) as aggregated_recommendation_count,
        sum(parsed_cost_count) as parsed_cost_count,
        sum(
            range_parsed_count
            + single_value_parsed_count
            + missing_cost_count
            + bare_number_unsupported_count
            + encoding_error_count
            + non_gbp_currency_count
            + unsupported_format_count
            + invalid_bounds_count
            + numeric_overflow_count
        ) as partitioned_recommendation_count
    from {{ ref('int_epc_recommendation_agg') }}
),

certificates as (
    select count(*) as certificate_count
    from {{ ref('fct_epc_certificate') }}
)

select
    facts.recommendation_count,
    facts.orphan_count,
    facts.parented_count,
    aggregates.aggregated_recommendation_count,
    aggregates.partitioned_recommendation_count,
    aggregates.certificate_count as aggregate_certificate_count,
    certificates.certificate_count
from facts
cross join aggregates
cross join certificates
where
    facts.recommendation_count <> facts.parented_count + facts.orphan_count
    or facts.parented_count <> aggregates.aggregated_recommendation_count
    or facts.parented_count <> aggregates.partitioned_recommendation_count
    or aggregates.certificate_count <> certificates.certificate_count
