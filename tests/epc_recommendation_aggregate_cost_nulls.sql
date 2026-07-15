select
    epc_certificate_key,
    recommendation_count,
    parsed_cost_count,
    indicative_cost_low_total_gbp,
    indicative_cost_high_total_gbp,
    cost_parse_coverage_ratio,
    mapping_coverage_ratio,
    mapper_version,
    mapping_status
from {{ ref('int_epc_recommendation_agg') }}
where
    (
        parsed_cost_count = 0
        and (
            indicative_cost_low_total_gbp is not null
            or indicative_cost_high_total_gbp is not null
        )
    )
    or (
        parsed_cost_count > 0
        and (
            indicative_cost_low_total_gbp is null
            or indicative_cost_high_total_gbp is null
            or indicative_cost_low_total_gbp > indicative_cost_high_total_gbp
        )
    )
    or (recommendation_count = 0 and cost_parse_coverage_ratio is not null)
    or mapping_coverage_ratio is not null
    or mapper_version <> 'NOT_RUN'
    or mapping_status <> 'NOT_RUN'
