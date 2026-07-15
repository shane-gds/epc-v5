{{ config(materialized='table', tags=['core', 'recommendation', 'support']) }}

select
    epc_certificate_key,
    count(*) as recommendation_count,
    count(*) filter (
        where cost_parse_status in ('RANGE_PARSED', 'SINGLE_VALUE_PARSED')
    ) as parsed_cost_count,
    count(*) filter (where cost_parse_status = 'RANGE_PARSED') as range_parsed_count,
    count(*) filter (where cost_parse_status = 'SINGLE_VALUE_PARSED')
        as single_value_parsed_count,
    count(*) filter (where cost_parse_status = 'MISSING') as missing_cost_count,
    count(*) filter (where cost_parse_status = 'BARE_NUMBER_UNSUPPORTED')
        as bare_number_unsupported_count,
    count(*) filter (where cost_parse_status = 'ENCODING_ERROR') as encoding_error_count,
    count(*) filter (where cost_parse_status = 'NON_GBP_CURRENCY') as non_gbp_currency_count,
    count(*) filter (where cost_parse_status = 'UNSUPPORTED_FORMAT')
        as unsupported_format_count,
    count(*) filter (where cost_parse_status = 'INVALID_BOUNDS') as invalid_bounds_count,
    count(*) filter (where cost_parse_status = 'NUMERIC_OVERFLOW') as numeric_overflow_count,
    count(*) filter (where recommendation_text_status = 'OBSERVED') as observed_text_count,
    count(*) filter (where recommendation_text_status = 'MISSING') as missing_text_count,
    sum(indicative_cost_low_gbp) filter (
        where cost_parse_status in ('RANGE_PARSED', 'SINGLE_VALUE_PARSED')
    )::decimal(20, 2) as indicative_cost_low_total_gbp,
    sum(indicative_cost_high_gbp) filter (
        where cost_parse_status in ('RANGE_PARSED', 'SINGLE_VALUE_PARSED')
    )::decimal(20, 2) as indicative_cost_high_total_gbp,
    min(loaded_at) as first_source_loaded_at,
    max(loaded_at) as last_source_loaded_at,
    bit_xor(hash(epc_recommendation_key)) as operational_recommendation_checksum
from {{ ref('fct_epc_recommendation_observation') }}
where epc_certificate_key is not null
group by epc_certificate_key
