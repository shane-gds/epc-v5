{{ config(materialized='table', tags=['core', 'dimension', 'geography', 'reference']) }}

select
    {{ stable_sha256(
        'epc-v4.geography.reference',
        'v1',
        ['geography_type', 'geography_code', 'release_key']
    ) }} as geography_key,
    geography_reference_profile_key,
    geography_type,
    geography_code,
    geography_name,
    geography_name_welsh,
    is_co_terminous,
    co_terminous_status,
    dataset_release_id as geography_release_id,
    release_key as geography_release_key,
    release_label as geography_release_label,
    cast(null as varchar) as parent_geography_key,
    cast(null as varchar) as country_code,
    cast(null as date) as valid_from,
    cast(null as date) as valid_to,
    'NOT_SUPPLIED' as hierarchy_status,
    'NOT_SUPPLIED' as country_assignment_status,
    'NOT_SUPPLIED' as validity_status,
    dataset_release_id as source_dataset_release_id,
    representative_source_record_key as source_record_key,
    representative_source_file_id as source_file_id,
    representative_source_row_number as source_row_number,
    representative_pipeline_run_id as pipeline_run_id,
    representative_source_loaded_at as source_loaded_at,
    reference_observation_count,
    distinct_representation_count,
    reference_resolution_status,
    case
        when geography_type = 'LAD'
            then geography_release_label = '{{ var("lad_reference_release_label") }}'
        when geography_type = 'LPA'
            then geography_release_label = '{{ var("lpa_reference_release_label") }}'
        else false
    end as is_current_release,
    'geography_reference_v1' as geography_contract_version
from {{ ref('int_geography_reference_profile') }}
where reference_resolution_status <> 'CONFLICT'
