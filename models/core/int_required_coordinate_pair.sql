{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='coordinate_key',
    on_schema_change='append_new_columns',
    tags=['core', 'intermediate', 'location', 'coordinate-cache']
) }}

with coordinate_requests as (
    select
        coordinate_key,
        {{ canonical_bng_coordinate_value('easting') }} as easting,
        {{ canonical_bng_coordinate_value('northing') }} as northing,
        'DIRECT_UPRN' as coordinate_method,
        source_reference_count::ubigint as direct_uprn_reference_count,
        0::ubigint as postcode_allocation_tuple_count,
        0::ubigint as sector_unit_postcode_count
    from {{ ref('int_uprn_location') }}
    where
        location_resolution_status = 'RESOLVED_UNIQUE'
        and coordinate_parse_status = 'VALID'

    union all

    select
        coordinate_key,
        {{ canonical_bng_coordinate_value('centroid_easting') }} as easting,
        {{ canonical_bng_coordinate_value('centroid_northing') }} as northing,
        'POSTCODE_CENTROID' as coordinate_method,
        0::ubigint as direct_uprn_reference_count,
        source_allocation_tuple_count as postcode_allocation_tuple_count,
        0::ubigint as sector_unit_postcode_count
    from {{ ref('int_postcode_coordinate') }}

    union all

    select
        coordinate_key,
        {{ canonical_bng_coordinate_value('centroid_easting') }} as easting,
        {{ canonical_bng_coordinate_value('centroid_northing') }} as northing,
        'POSTCODE_SECTOR_CENTROID' as coordinate_method,
        0::ubigint as direct_uprn_reference_count,
        0::ubigint as postcode_allocation_tuple_count,
        unit_postcode_count::ubigint as sector_unit_postcode_count
    from {{ ref('int_postcode_sector_coordinate') }}
),

pair_profile as (
    select
        coordinate_key,
        easting,
        northing,
        count(*)::uinteger as source_request_count,
        count(*)::ubigint as reference_count,
        sum(direct_uprn_reference_count)::ubigint as direct_uprn_reference_count,
        sum(postcode_allocation_tuple_count)::ubigint as postcode_allocation_tuple_count,
        sum(sector_unit_postcode_count)::ubigint as sector_unit_postcode_count,
        bool_or(coordinate_method = 'DIRECT_UPRN') as has_direct_uprn,
        bool_or(coordinate_method = 'POSTCODE_CENTROID') as has_postcode_centroid,
        bool_or(coordinate_method = 'POSTCODE_SECTOR_CENTROID')
            as has_postcode_sector_centroid
    from coordinate_requests
    group by coordinate_key, easting, northing
)

select
    coordinate_key,
    easting,
    northing,
    '{{ var("coordinate_source_crs") }}' as source_crs,
    '{{ var("coordinate_target_crs") }}' as target_crs,
    '{{ var("coordinate_transform_contract_version") }}' as transform_contract_version,
    source_request_count,
    reference_count,
    direct_uprn_reference_count,
    postcode_allocation_tuple_count,
    sector_unit_postcode_count,
    list_concat(
        if(has_direct_uprn, ['DIRECT_UPRN'], []),
        if(has_postcode_centroid, ['POSTCODE_CENTROID'], []),
        if(has_postcode_sector_centroid, ['POSTCODE_SECTOR_CENTROID'], [])
    ) as coordinate_methods,
    (
        has_direct_uprn::uinteger
        + has_postcode_centroid::uinteger
        + has_postcode_sector_centroid::uinteger
    ) as coordinate_method_count,
    case
        when easting between 0 and 700000 and northing between 0 and 1300000 then 'VALID'
        else 'OUT_OF_BOUNDS'
    end as validation_status,
    'required_coordinate_pair_v1' as coordinate_pair_contract_version
from pair_profile
