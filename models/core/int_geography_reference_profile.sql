{{ config(materialized='table', tags=['core', 'intermediate', 'geography', 'reference']) }}

with observations as (
    select
        geography_type,
        geography_code,
        geography_name,
        geography_name_welsh_observation as geography_name_welsh,
        cast(null as boolean) as is_co_terminous,
        'NOT_APPLICABLE' as co_terminous_status,
        dataset_release_id,
        release_key,
        release_label,
        source_record_key,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at
    from {{ ref('stg_lad_name_code_reference') }}
    where geography_parse_status = 'VALID'

    union all

    select
        geography_type,
        geography_code,
        geography_name,
        cast(null as varchar) as geography_name_welsh,
        is_co_terminous,
        co_terminous_parse_status as co_terminous_status,
        dataset_release_id,
        release_key,
        release_label,
        source_record_key,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at
    from {{ ref('stg_lpa_name_code_reference') }}
    where geography_parse_status = 'VALID'
)

select
    {{ stable_sha256(
        'epc-v5.geography.reference-profile',
        'v1',
        ['geography_type', 'geography_code', 'release_key']
    ) }} as geography_reference_profile_key,
    geography_type,
    geography_code,
    max(dataset_release_id) as dataset_release_id,
    release_key,
    max(release_label) as release_label,
    arg_min(geography_name, source_record_key) as geography_name,
    arg_min(geography_name_welsh, source_record_key) as geography_name_welsh,
    arg_min(is_co_terminous, source_record_key) as is_co_terminous,
    arg_min(co_terminous_status, source_record_key) as co_terminous_status,
    cast(count(*) as uinteger) as reference_observation_count,
    cast(count(distinct struct_pack(
        geography_name := geography_name,
        geography_name_welsh := geography_name_welsh,
        is_co_terminous := is_co_terminous,
        co_terminous_status := co_terminous_status
    )) as uinteger) as distinct_representation_count,
    case
        when count(distinct struct_pack(
            geography_name := geography_name,
            geography_name_welsh := geography_name_welsh,
            is_co_terminous := is_co_terminous,
            co_terminous_status := co_terminous_status
        )) > 1 then 'CONFLICT'
        when count(*) > 1 then 'EXACT_DUPLICATE'
        else 'UNIQUE'
    end as reference_resolution_status,
    min(source_record_key) as representative_source_record_key,
    arg_min(source_file_id, source_record_key) as representative_source_file_id,
    arg_min(source_row_number, source_record_key) as representative_source_row_number,
    arg_min(pipeline_run_id, source_record_key) as representative_pipeline_run_id,
    arg_min(loaded_at, source_record_key) as representative_source_loaded_at,
    'geography_reference_profile_v1' as reference_profile_contract_version
from observations
group by geography_type, geography_code, release_key
