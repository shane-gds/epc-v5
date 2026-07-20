{{ config(materialized='table', tags=['core', 'intermediate', 'location']) }}

with allocation_profile as (
    select
        required.required_uprn_key,
        required.onsud_dataset_release_id,
        required.onsud_release_key,
        required.onsud_release_label,
        required.uprn,
        required.requirement_reason,
        required.requirement_scope,
        required.source_reference_count,
        count(allocation.onsud_allocation_key) as allocation_tuple_count,
        max(allocation.onsud_allocation_key) as candidate_allocation_key,
        max(allocation.allocation_status) as candidate_allocation_status,
        max(allocation.postcode) as candidate_postcode,
        max(allocation.postcode_sector) as candidate_postcode_sector,
        max(allocation.easting) as candidate_easting,
        max(allocation.northing) as candidate_northing,
        max(allocation.coordinate_parse_status) as candidate_coordinate_parse_status,
        max(allocation.lsoa_code) as candidate_lsoa_code,
        max(allocation.msoa_code) as candidate_msoa_code,
        max(allocation.lad_code) as candidate_lad_code,
        max(allocation.geography_parse_status) as candidate_geography_parse_status,
        max(allocation.source_record_count) as candidate_source_record_count
    from {{ ref('int_required_uprn') }} as required
    left join {{ ref('stg_onsud_uprn_allocation') }} as allocation
        on
            required.onsud_dataset_release_id = allocation.dataset_release_id
            and required.uprn = allocation.uprn
    group by
        required.required_uprn_key, required.onsud_dataset_release_id,
        required.onsud_release_key, required.onsud_release_label, required.uprn,
        required.requirement_reason, required.requirement_scope,
        required.source_reference_count
),

classified as (
    select
        *,
        case
            when allocation_tuple_count = 0 then 'MISSING_IN_RELEASE'
            when allocation_tuple_count = 1 and candidate_allocation_status <> 'CONFLICT'
                then 'RESOLVED_UNIQUE'
            else 'CONFLICTING_ALLOCATIONS'
        end as location_resolution_status
    from allocation_profile
)

select
    {{ stable_sha256(
        'epc-v5.location.uprn-location',
        'v1',
        ['onsud_release_key', 'cast(uprn as varchar)']
    ) }} as uprn_location_key,
    required_uprn_key,
    onsud_dataset_release_id,
    onsud_release_key,
    onsud_release_label,
    uprn,
    requirement_reason,
    requirement_scope,
    source_reference_count,
    allocation_tuple_count,
    location_resolution_status,
    case
        when location_resolution_status = 'RESOLVED_UNIQUE'
            then candidate_allocation_key
    end as onsud_allocation_key,
    case
        when location_resolution_status = 'RESOLVED_UNIQUE'
            then candidate_postcode
    end as postcode,
    case
        when location_resolution_status = 'RESOLVED_UNIQUE'
            then candidate_postcode_sector
    end as postcode_sector,
    case
        when
            location_resolution_status = 'RESOLVED_UNIQUE'
            and candidate_coordinate_parse_status = 'VALID'
            then candidate_easting
    end as easting,
    case
        when
            location_resolution_status = 'RESOLVED_UNIQUE'
            and candidate_coordinate_parse_status = 'VALID'
            then candidate_northing
    end as northing,
    case
        when location_resolution_status = 'RESOLVED_UNIQUE'
            then candidate_coordinate_parse_status
    end as coordinate_parse_status,
    case
        when location_resolution_status = 'RESOLVED_UNIQUE'
            then candidate_lsoa_code
    end as lsoa_code,
    case
        when location_resolution_status = 'RESOLVED_UNIQUE'
            then candidate_msoa_code
    end as msoa_code,
    case
        when location_resolution_status = 'RESOLVED_UNIQUE'
            then candidate_lad_code
    end as lad_code,
    case
        when location_resolution_status = 'RESOLVED_UNIQUE'
            then candidate_geography_parse_status
    end as geography_parse_status,
    case
        when location_resolution_status = 'RESOLVED_UNIQUE'
            then candidate_source_record_count
    end as onsud_source_record_count,
    case
        when
            location_resolution_status = 'RESOLVED_UNIQUE'
            and candidate_coordinate_parse_status = 'VALID'
            then {{ bng_wgs84_coordinate_key('candidate_easting', 'candidate_northing') }}
    end as coordinate_key,
    case
        when
            location_resolution_status = 'RESOLVED_UNIQUE'
            and candidate_coordinate_parse_status = 'VALID'
            then '{{ var("coordinate_source_crs") }}'
    end as source_crs,
    case
        when
            location_resolution_status = 'RESOLVED_UNIQUE'
            and candidate_coordinate_parse_status = 'VALID'
            then '{{ var("coordinate_target_crs") }}'
    end as target_crs,
    case
        when
            location_resolution_status = 'RESOLVED_UNIQUE'
            and candidate_coordinate_parse_status = 'VALID'
            then '{{ var("coordinate_transform_contract_version") }}'
    end as transform_contract_version,
    'uprn_location_v2' as location_contract_version
from classified
