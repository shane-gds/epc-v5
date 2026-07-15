{{ config(materialized='table', tags=['silver', 'pp']) }}

with source as (
    select
        *,
        nullif(trim(transaction_id_raw), '') as transaction_id_value,
        try_strptime(trim(transfer_date_raw), '%Y-%m-%d %H:%M') as transfer_timestamp_value,
        try_cast(trim(price_paid_raw) as decimal(18, 2)) as price_paid_value
    from {{ source('bronze_ingestion', 'raw_pp_transaction') }}
),

accepted as (
    select *
    from source
    where
        transaction_id_value is not null
        and transfer_timestamp_value is not null
        and price_paid_value > 0
)

select
    source_record_key,
    dataset_release_id,
    source_file_id,
    source_row_number,
    pipeline_run_id,
    loaded_at,
    transaction_id_value as transaction_id,
    cast(transfer_timestamp_value as date) as transfer_date,
    price_paid_value as price_paid,
    nullif(trim(paon_raw), '') as paon,
    nullif(trim(saon_raw), '') as saon,
    nullif(trim(street_raw), '') as street,
    nullif(trim(locality_raw), '') as locality,
    nullif(trim(town_city_raw), '') as town_city,
    nullif(trim(district_raw), '') as district,
    nullif(trim(county_raw), '') as county,
    {{ normalise_uk_postcode('postcode_raw') }} as postcode,
    {{ uk_postcode_parse_status('postcode_raw') }} as postcode_parse_status,
    {{ normalise_address(
        "concat_ws(' ', nullif(trim(paon_raw), ''), nullif(trim(saon_raw), ''), nullif(trim(street_raw), ''), nullif(trim(locality_raw), ''), nullif(trim(town_city_raw), ''), nullif(trim(district_raw), ''), nullif(trim(county_raw), ''))"
    ) }} as address_comparison,
    'address_v1' as normaliser_version,
    upper(nullif(trim(property_type_raw), '')) as property_type,
    upper(nullif(trim(old_new_raw), '')) as old_new,
    upper(nullif(trim(duration_raw), '')) as duration,
    upper(nullif(trim(category_raw), '')) as ppd_category,
    case upper(nullif(trim(category_raw), ''))
        when 'B' then true
        when 'A' then false
    end as is_additional_ppd_transaction,
    case
        when nullif(trim(category_raw), '') is null then 'MISSING'
        when upper(trim(category_raw)) in ('A', 'B') then 'VALID'
        else 'UNKNOWN'
    end as category_status,
    upper(nullif(trim(record_status_raw), '')) as record_status,
    'VALID' as parse_status
from accepted
