{{ config(materialized='table', tags=['silver', 'reference', 'geography']) }}

with source as (
    select
        bronze.*,
        dataset_release.release_key,
        dataset_release.release_label,
        upper(nullif(trim(bronze.lpa25cd_raw), '')) as geography_code_observation,
        nullif(trim(bronze.lpa25nm_raw), '') as geography_name_observation,
        upper(nullif(trim(bronze.co_terminous_raw), '')) as co_terminous_observation,
        {{ try_strict_unsigned_integer('bronze.objectid_raw', 'ubigint') }}
            as object_id_observation
    from {{ source('bronze_ingestion', 'raw_lpa_name_code') }} as bronze
    inner join {{ source('audit_ingestion', 'audit_dataset_release') }} as dataset_release
        on
            bronze.dataset_release_id = dataset_release.dataset_release_id
            and dataset_release.dataset_code = 'ONS_LPA_NAMES_CODES'
),

classified as (
    select
        *,
        case
            when geography_code_observation is null then 'MISSING_CODE'
            when not regexp_full_match(geography_code_observation, '^[ENSW][0-9]{8}$')
                then 'INVALID_CODE'
            when geography_name_observation is null then 'MISSING_NAME'
            else 'VALID'
        end as geography_parse_status,
        case
            when co_terminous_observation is null then 'MISSING'
            when co_terminous_observation in ('Y', 'N') then 'VALID'
            else 'INVALID'
        end as co_terminous_parse_status,
        case
            when nullif(trim(objectid_raw), '') is null then 'MISSING'
            when object_id_observation is null then 'INVALID'
            else 'VALID'
        end as object_id_parse_status
    from source
)

select
    {{ stable_sha256(
        'epc-v5.geography.reference-observation',
        'v1',
        ['release_key', "'LPA'", 'source_record_key']
    ) }} as geography_reference_observation_key,
    'LPA' as geography_type,
    geography_code_observation,
    case when geography_parse_status = 'VALID' then geography_code_observation end
        as geography_code,
    geography_name_observation,
    case when geography_parse_status = 'VALID' then geography_name_observation end
        as geography_name,
    co_terminous_observation,
    case
        when co_terminous_parse_status = 'VALID' then co_terminous_observation = 'Y'
    end as is_co_terminous,
    co_terminous_parse_status,
    geography_parse_status,
    objectid_raw as object_id_observation_raw,
    object_id_observation,
    object_id_parse_status,
    dataset_release_id,
    release_key,
    release_label,
    source_record_key,
    source_file_id,
    source_row_number,
    pipeline_run_id,
    parser_contract_version,
    loaded_at,
    'lpa_name_code_reference_v1' as reference_contract_version
from classified
