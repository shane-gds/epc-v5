-- noqa: disable=AL03
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='quarantine_event_key',
    tags=['audit', 'silver_gate']
) }}

with pp as (
    select
        *,
        nullif(trim(transaction_id_raw), '') as transaction_id_value,
        try_strptime(trim(transfer_date_raw), '%Y-%m-%d %H:%M') as transfer_timestamp_value,
        try_cast(trim(price_paid_raw) as decimal(18, 2)) as price_paid_value
    from {{ source('bronze_ingestion', 'raw_pp_transaction') }}
),

epc as (
    select
        *,
        nullif(trim(certificate_number_raw), '') as certificate_number_value,
        nullif(trim(inspection_date_raw), '') as inspection_date_text,
        try_strptime(trim(inspection_date_raw), '%Y-%m-%d') as inspection_timestamp_value,
        nullif(trim(lodgement_date_raw), '') as lodgement_date_text,
        try_strptime(trim(lodgement_date_raw), '%Y-%m-%d') as lodgement_timestamp_value,
        upper(nullif(trim(current_energy_rating_raw), '')) as current_rating_value,
        try_cast(trim(current_energy_efficiency_raw) as smallint) as current_efficiency_value
    from {{ source('bronze_ingestion', 'raw_epc_certificate') }}
),

recommendation as (
    select
        *,
        nullif(trim(certificate_number_raw), '') as certificate_number_value,
        {{ try_strict_unsigned_integer('improvement_item_raw', 'integer') }}
            as improvement_item_value
    from {{ source('bronze_ingestion', 'raw_epc_recommendation') }}
),

onsud as (
    select
        *,
        {{ try_strict_unsigned_integer('uprn_raw', 'ubigint') }} as uprn_value
    from {{ source('bronze_ingestion', 'raw_onsud_uprn') }}
),

failures as (
    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at as source_loaded_at,
        'PPD' as source_dataset,
        'pp_silver_validation_v1' as validation_contract_version,
        'MISSING_TRANSACTION_ID' as rule_code,
        json_object('transaction_id_raw', transaction_id_raw) as raw_payload
    from pp
    where transaction_id_value is null

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'PPD',
        'pp_silver_validation_v1',
        'INVALID_TRANSFER_DATE',
        json_object('transfer_date_raw', transfer_date_raw)
    from pp
    where transfer_timestamp_value is null

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'PPD',
        'pp_silver_validation_v1',
        'INVALID_PRICE_PAID',
        json_object('price_paid_raw', price_paid_raw)
    from pp
    where price_paid_value is null or price_paid_value <= 0

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'EPC_CERTIFICATE',
        'epc_silver_validation_v1',
        'MISSING_CERTIFICATE_NUMBER',
        json_object('certificate_number_raw', certificate_number_raw)
    from epc
    where certificate_number_value is null

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'EPC_CERTIFICATE',
        'epc_silver_validation_v1',
        'MISSING_INSPECTION_DATE',
        json_object('inspection_date_raw', inspection_date_raw)
    from epc
    where inspection_date_text is null

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'EPC_CERTIFICATE',
        'epc_silver_validation_v1',
        'INVALID_INSPECTION_DATE',
        json_object('inspection_date_raw', inspection_date_raw)
    from epc
    where inspection_date_text is not null and inspection_timestamp_value is null

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'EPC_CERTIFICATE',
        'epc_silver_validation_v1',
        'MISSING_LODGEMENT_DATE',
        json_object('lodgement_date_raw', lodgement_date_raw)
    from epc
    where lodgement_date_text is null

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'EPC_CERTIFICATE',
        'epc_silver_validation_v1',
        'INVALID_LODGEMENT_DATE',
        json_object('lodgement_date_raw', lodgement_date_raw)
    from epc
    where lodgement_date_text is not null and lodgement_timestamp_value is null

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'EPC_CERTIFICATE',
        'epc_silver_validation_v1',
        'INVALID_CURRENT_ENERGY_RATING',
        json_object('current_energy_rating_raw', current_energy_rating_raw)
    from epc
    where
        current_rating_value is null
        or current_rating_value not in ('A', 'B', 'C', 'D', 'E', 'F', 'G')

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'EPC_CERTIFICATE',
        'epc_silver_validation_v1',
        'INVALID_CURRENT_ENERGY_EFFICIENCY',
        json_object('current_energy_efficiency_raw', current_energy_efficiency_raw)
    from epc
    where current_efficiency_value is null or current_efficiency_value <= 0

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'EPC_RECOMMENDATION',
        'recommendation_silver_validation_v1',
        'MISSING_CERTIFICATE_NUMBER',
        json_object('certificate_number_raw', certificate_number_raw)
    from recommendation
    where certificate_number_value is null

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'EPC_RECOMMENDATION',
        'recommendation_silver_validation_v1',
        'INVALID_IMPROVEMENT_ITEM',
        json_object('improvement_item_raw', improvement_item_raw)
    from recommendation
    where improvement_item_value is null or improvement_item_value <= 0

    union all

    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'ONSUD',
        'onsud_silver_validation_v1',
        'INVALID_UPRN',
        json_object('uprn_raw', uprn_raw)
    from onsud
    where uprn_value is null or uprn_value = 0
),

events as (
    select
        {{ stable_sha256(
            'epc-v4.audit.quarantine-source-record',
            'v1',
            ['source_record_key', 'validation_contract_version', 'rule_code']
        ) }} as quarantine_event_key,
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        source_dataset,
        validation_contract_version,
        rule_code,
        raw_payload,
        'NOT_REPLAYED' as replay_status,
        source_loaded_at,
        current_timestamp as quarantined_at
    from failures
)

select *
from events
{% if is_incremental() %}
    where not exists (
        select 1
        from {{ this }} as existing_event
        where existing_event.quarantine_event_key = events.quarantine_event_key
    )
{% endif %}
