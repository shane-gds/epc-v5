{{ config(materialized='table', tags=['silver', 'onsud']) }}

with source as (
    select
        bronze.*,
        dataset_release.release_key,
        {{ try_strict_unsigned_integer('bronze.uprn_raw', 'ubigint') }} as uprn_value,
        {{ try_strict_integer('bronze.gridgb1e_raw', 'integer') }} as easting_value,
        {{ try_strict_integer('bronze.gridgb1n_raw', 'integer') }} as northing_value,
        {{ normalise_uk_postcode('bronze.pcds_raw') }} as postcode_value,
        {{ uk_postcode_parse_status('bronze.pcds_raw') }} as postcode_status_value,
        {{ uk_postcode_sector('bronze.pcds_raw') }} as postcode_sector_value,
        nullif(trim(bronze.lsoa21cd_raw), '') as lsoa_code_value,
        nullif(trim(bronze.msoa21cd_raw), '') as msoa_code_value,
        nullif(trim(bronze.lad25cd_raw), '') as lad_code_value
    from {{ source('bronze_ingestion', 'raw_onsud_uprn') }} as bronze
    inner join {{ source('audit_ingestion', 'audit_dataset_release') }} as dataset_release
        on
            bronze.dataset_release_id = dataset_release.dataset_release_id
            and dataset_release.dataset_code = 'ONSUD'
),

accepted as (
    select
        *,
        case
            when easting_value is null and northing_value is null then 'MISSING'
            when easting_value is null or northing_value is null then 'PARTIAL'
            when
                easting_value < 0 or easting_value > 700000
                or northing_value < 0 or northing_value > 1300000 then 'OUT_OF_BOUNDS'
            else 'VALID'
        end as coordinate_parse_status_value,
        case
            when lsoa_code_value is null and msoa_code_value is null and lad_code_value is null
                then 'MISSING'
            when lsoa_code_value is null or msoa_code_value is null or lad_code_value is null
                then 'PARTIAL'
            when
                regexp_full_match(lsoa_code_value, '^[EWS][0-9]{8}$')
                and regexp_full_match(msoa_code_value, '^[EWS][0-9]{8}$')
                and regexp_full_match(lad_code_value, '^[EWS][0-9]{8}$') then 'VALID'
            else 'INVALID'
        end as geography_parse_status_value
    from source
    where uprn_value is not null and uprn_value > 0
),

keyed as (
    select
        *,
        {{ stable_sha256(
            'uk.gov.ons.onsud.uprn-allocation',
            'v1',
            [
                'release_key',
                'cast(uprn_value as varchar)',
                'postcode_value',
                'cast(easting_value as varchar)',
                'cast(northing_value as varchar)',
                'lsoa_code_value',
                'msoa_code_value',
                'lad_code_value'
            ]
        ) }} as onsud_allocation_key
    from accepted
),

allocation_tuple as (
    select
        onsud_allocation_key,
        dataset_release_id,
        release_key,
        uprn_value as uprn,
        postcode_value as postcode,
        postcode_sector_value as postcode_sector,
        postcode_status_value as postcode_parse_status,
        easting_value as easting,
        northing_value as northing,
        coordinate_parse_status_value as coordinate_parse_status,
        lsoa_code_value as lsoa_code,
        msoa_code_value as msoa_code,
        lad_code_value as lad_code,
        geography_parse_status_value as geography_parse_status,
        min(source_record_key) as representative_source_record_key,
        count(*) as source_record_count,
        count(distinct source_file_id) as source_file_count
    from keyed
    group by
        onsud_allocation_key, dataset_release_id, release_key, uprn_value,
        postcode_value, postcode_sector_value, postcode_status_value,
        easting_value, northing_value, coordinate_parse_status_value,
        lsoa_code_value, msoa_code_value, lad_code_value, geography_parse_status_value
),

uprn_profile as (
    select
        dataset_release_id,
        uprn,
        count(*) as distinct_allocation_count
    from allocation_tuple
    group by dataset_release_id, uprn
)

select
    allocation.*,
    profile.distinct_allocation_count,
    'onsud_allocation_v1' as allocation_contract_version,
    case
        when profile.distinct_allocation_count > 1 then 'CONFLICT'
        when allocation.source_record_count > 1 then 'EXACT_DUPLICATE'
        else 'UNIQUE'
    end as allocation_status
from allocation_tuple as allocation
inner join uprn_profile as profile
    on
        allocation.dataset_release_id = profile.dataset_release_id
        and allocation.uprn = profile.uprn
