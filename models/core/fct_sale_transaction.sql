{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='sale_transaction_key',
    on_schema_change='append_new_columns',
    tags=['core', 'fact', 'pp']
) }}

with staged as (
    select
        pp_observation.*,
        dataset_release.release_key
    from {{ ref('stg_pp_transaction_observation') }} as pp_observation
    inner join {{ source('audit_ingestion', 'audit_dataset_release') }} as dataset_release
        on pp_observation.dataset_release_id = dataset_release.dataset_release_id
),

facts as (
    select
        {{ stable_sha256(
            'uk.gov.landregistry.ppd.sale-transaction',
            'v1',
            ['transaction_id', 'record_status']
        ) }} as sale_transaction_key,
        transaction_id,
        transfer_date,
        price_paid,
        'GBP' as currency_code,
        paon,
        saon,
        street,
        locality,
        town_city,
        district,
        county,
        postcode,
        postcode_parse_status,
        property_type,
        old_new,
        duration,
        ppd_category,
        is_additional_ppd_transaction,
        category_status,
        record_status as publisher_record_status,
        case record_status
            when 'A' then 'ACTIVE'
            when 'C' then 'CORRECTED'
            when 'D' then 'DELETED'
            else 'UNKNOWN'
        end as record_status,
        source_record_key,
        dataset_release_id,
        release_key,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'sale_transaction_v1' as fact_contract_version
    from staged
)

select *
from facts
{% if is_incremental() %}
    where not exists (
        select 1
        from {{ this }} as existing_fact
        where existing_fact.sale_transaction_key = facts.sale_transaction_key
    )
{% endif %}
