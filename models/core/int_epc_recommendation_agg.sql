{{ config(materialized='table', tags=['core', 'recommendation', 'aggregate']) }}

select
    certificate.epc_certificate_key,
    certificate.certificate_number,
    certificate.dataset_release_id,
    certificate.release_key,
    observed.indicative_cost_low_total_gbp,
    observed.indicative_cost_high_total_gbp,
    cast(null as uinteger) as mapping_eligible_count,
    cast(null as uinteger) as mapped_recommendation_count,
    cast(null as double) as mapping_coverage_ratio,
    'NOT_RUN' as mapper_version,
    'NOT_RUN' as mapping_status,
    observed.first_source_loaded_at,
    observed.last_source_loaded_at,
    observed.operational_recommendation_checksum,
    'epc_recommendation_aggregate_v1' as aggregate_contract_version,
    cast(coalesce(observed.recommendation_count, 0) as uinteger) as recommendation_count,
    cast(coalesce(observed.parsed_cost_count, 0) as uinteger) as parsed_cost_count,
    cast(coalesce(observed.range_parsed_count, 0) as uinteger) as range_parsed_count,
    cast(coalesce(observed.single_value_parsed_count, 0) as uinteger)
        as single_value_parsed_count,
    cast(coalesce(observed.missing_cost_count, 0) as uinteger) as missing_cost_count,
    cast(coalesce(observed.bare_number_unsupported_count, 0) as uinteger)
        as bare_number_unsupported_count,
    cast(coalesce(observed.encoding_error_count, 0) as uinteger) as encoding_error_count,
    cast(coalesce(observed.non_gbp_currency_count, 0) as uinteger)
        as non_gbp_currency_count,
    cast(coalesce(observed.unsupported_format_count, 0) as uinteger)
        as unsupported_format_count,
    cast(coalesce(observed.invalid_bounds_count, 0) as uinteger) as invalid_bounds_count,
    cast(coalesce(observed.numeric_overflow_count, 0) as uinteger) as numeric_overflow_count,
    cast(coalesce(observed.observed_text_count, 0) as uinteger) as observed_text_count,
    cast(coalesce(observed.missing_text_count, 0) as uinteger) as missing_text_count,
    case
        when coalesce(observed.recommendation_count, 0) = 0 then null
        else cast(observed.parsed_cost_count as double) / observed.recommendation_count
    end as cost_parse_coverage_ratio,
    case
        when coalesce(observed.recommendation_count, 0) = 0 then 'NO_RECOMMENDATIONS'
        when observed.parsed_cost_count = 0 then 'NO_PARSED_COSTS'
        when observed.parsed_cost_count = observed.recommendation_count then 'COMPLETE_COSTS'
        else 'PARTIAL_COSTS'
    end as aggregate_status,
    current_timestamp as aggregated_at
from {{ ref('fct_epc_certificate') }} as certificate
left join {{ ref('int_epc_recommendation_observed_agg') }} as observed
    on certificate.epc_certificate_key = observed.epc_certificate_key
