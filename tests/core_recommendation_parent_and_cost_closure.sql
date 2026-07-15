select
    epc_recommendation_key,
    parent_status,
    epc_certificate_key,
    cost_parse_status,
    indicative_cost_low_gbp,
    indicative_cost_high_gbp
from {{ ref('fct_epc_recommendation_observation') }}
where
    (parent_status = 'MATCHED_CERTIFICATE' and epc_certificate_key is null)
    or (parent_status = 'ORPHAN_CERTIFICATE' and epc_certificate_key is not null)
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
        and (
            indicative_cost_low_gbp is not null
            or indicative_cost_high_gbp is not null
        )
    )
