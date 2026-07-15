select
    source_record_key,
    parent_status,
    cost_parse_status,
    indicative_cost_low_gbp,
    indicative_cost_high_gbp
from {{ ref('stg_epc_recommendation_observation') }}
where
    parent_status not in ('MATCHED_CERTIFICATE', 'ORPHAN_CERTIFICATE', 'CONFLICTING_CERTIFICATE')
    or (
        cost_parse_status in ('RANGE_PARSED', 'SINGLE_VALUE_PARSED')
        and (
            indicative_cost_low_gbp is null
            or indicative_cost_high_gbp is null
            or indicative_cost_low_gbp > indicative_cost_high_gbp
        )
    )
    or (
        cost_parse_status not in ('RANGE_PARSED', 'SINGLE_VALUE_PARSED')
        and (indicative_cost_low_gbp is not null or indicative_cost_high_gbp is not null)
    )
