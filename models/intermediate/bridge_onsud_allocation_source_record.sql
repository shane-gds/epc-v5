{{ config(materialized='table', tags=['intermediate', 'location']) }}

with source as (
    select
        bronze.source_record_key,
        bronze.dataset_release_id,
        bronze.source_file_id,
        bronze.source_row_number,
        bronze.pipeline_run_id,
        dataset_release.release_key,
        {{ try_strict_unsigned_integer('bronze.uprn_raw', 'ubigint') }} as uprn,
        {{ try_strict_integer('bronze.gridgb1e_raw', 'integer') }} as easting,
        {{ try_strict_integer('bronze.gridgb1n_raw', 'integer') }} as northing,
        {{ normalise_uk_postcode('bronze.pcds_raw') }} as postcode,
        nullif(trim(bronze.lsoa21cd_raw), '') as lsoa_code,
        nullif(trim(bronze.msoa21cd_raw), '') as msoa_code,
        nullif(trim(bronze.lad25cd_raw), '') as lad_code
    from {{ source('bronze_ingestion', 'raw_onsud_uprn') }} as bronze
    inner join {{ source('audit_ingestion', 'audit_dataset_release') }} as dataset_release
        on
            bronze.dataset_release_id = dataset_release.dataset_release_id
            and dataset_release.dataset_code = 'ONSUD'
),

keyed as (
    select
        *,
        {{ stable_sha256(
            'uk.gov.ons.onsud.uprn-allocation',
            'v1',
            [
                'release_key',
                'cast(uprn as varchar)',
                'postcode',
                'cast(easting as varchar)',
                'cast(northing as varchar)',
                'lsoa_code',
                'msoa_code',
                'lad_code'
            ]
        ) }} as onsud_allocation_key
    from source
    where uprn is not null and uprn > 0
)

select
    keyed.source_record_key,
    keyed.dataset_release_id,
    keyed.source_file_id,
    keyed.source_row_number,
    keyed.pipeline_run_id,
    keyed.onsud_allocation_key,
    keyed.uprn,
    allocation.allocation_status,
    'onsud_allocation_source_bridge_v1' as bridge_contract_version
from keyed
inner join {{ ref('stg_onsud_uprn_allocation') }} as allocation
    on keyed.onsud_allocation_key = allocation.onsud_allocation_key
