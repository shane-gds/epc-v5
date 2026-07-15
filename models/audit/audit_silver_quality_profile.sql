-- noqa: disable=AL03
{{ config(materialized='table', tags=['audit', 'silver_gate']) }}

with metrics as (
    select
        'PPD' as source_dataset,
        'SILVER_ROW_COUNT' as metric_name,
        count(*) as metric_value
    from {{ ref('stg_pp_transaction_observation') }}
    union all
    select
        'PPD',
        'INVALID_OR_MISSING_POSTCODE_COUNT',
        count(*)
    from {{ ref('stg_pp_transaction_observation') }}
    where postcode_parse_status <> 'VALID'
    union all
    select
        'EPC_CERTIFICATE',
        'SILVER_ROW_COUNT',
        count(*)
    from {{ ref('stg_epc_certificate_observation') }}
    union all
    select
        'EPC_CERTIFICATE',
        'MISSING_UPRN_COUNT',
        count(*)
    from {{ ref('stg_epc_certificate_observation') }}
    where uprn_parse_status = 'MISSING'
    union all
    select
        'EPC_CERTIFICATE',
        'CHRONOLOGY_EXCEPTION_COUNT',
        count(*)
    from {{ ref('stg_epc_certificate_observation') }}
    where chronology_status <> 'VALID'
    union all
    select
        'EPC_CERTIFICATE',
        'NATURAL_KEY_CONFLICT_COUNT',
        count(*)
    from {{ ref('stg_epc_certificate_observation') }}
    where certificate_conflict_status = 'CONFLICT'
    union all
    select
        'EPC_RECOMMENDATION',
        'SILVER_ROW_COUNT',
        count(*)
    from {{ ref('stg_epc_recommendation_observation') }}
    union all
    select
        'EPC_RECOMMENDATION',
        'ORPHAN_ROW_COUNT',
        count(*)
    from {{ ref('stg_epc_recommendation_observation') }}
    where parent_status = 'ORPHAN_CERTIFICATE'
    union all
    select
        'ONSUD',
        'ALLOCATION_ROW_COUNT',
        count(*)
    from {{ ref('stg_onsud_uprn_allocation') }}
    union all
    select
        'ONSUD',
        'ALLOCATION_CONFLICT_COUNT',
        count(*)
    from {{ ref('stg_onsud_uprn_allocation') }}
    where allocation_status = 'CONFLICT'
    union all
    select
        'LAD_REFERENCE',
        'SILVER_ROW_COUNT',
        count(*)
    from {{ ref('stg_lad_name_code_reference') }}
    union all
    select
        'LAD_REFERENCE',
        'INVALID_REFERENCE_COUNT',
        count(*)
    from {{ ref('stg_lad_name_code_reference') }}
    where geography_parse_status <> 'VALID'
    union all
    select
        'LPA_REFERENCE',
        'SILVER_ROW_COUNT',
        count(*)
    from {{ ref('stg_lpa_name_code_reference') }}
    union all
    select
        'LPA_REFERENCE',
        'INVALID_REFERENCE_COUNT',
        count(*)
    from {{ ref('stg_lpa_name_code_reference') }}
    where geography_parse_status <> 'VALID'
    union all
    select
        source_dataset,
        concat('QUARANTINE_', rule_code),
        count(*)
    from {{ ref('quarantine_source_record') }}
    group by source_dataset, rule_code
)

select
    {{ stable_sha256(
        'epc-v4.audit.silver-quality-metric',
        'v1',
        ['source_dataset', 'metric_name']
    ) }} as quality_metric_key,
    source_dataset,
    metric_name,
    metric_value,
    current_timestamp as profiled_at
from metrics
