{{ config(materialized='table', tags=['core', 'intermediate', 'location']) }}

with centroids as (
    select
        onsud_dataset_release_id,
        onsud_release_key,
        onsud_release_label,
        postcode,
        max(postcode_sector) as postcode_sector,
        {{ canonical_bng_coordinate_value('avg(easting)') }} as centroid_easting,
        {{ canonical_bng_coordinate_value('avg(northing)') }} as centroid_northing,
        count(*)::uinteger as distinct_point_count,
        sum(allocation_tuple_count)::ubigint as source_allocation_tuple_count,
        sum(conflicting_allocation_tuple_count)::ubigint
            as conflicting_allocation_tuple_count,
        sum(source_record_count)::ubigint as source_record_count,
        sqrt(
            power(max(easting) - min(easting), 2)
            + power(max(northing) - min(northing), 2)
        )::double as max_point_spread_m
    from {{ ref('int_postcode_coordinate_point') }}
    group by
        onsud_dataset_release_id,
        onsud_release_key,
        onsud_release_label,
        postcode
)

select
    {{ stable_sha256(
        'epc-v4.location.postcode-coordinate',
        'v1',
        ['onsud_release_key', 'postcode', "'POSTCODE_CENTROID'", "'BOUNDING_BOX_DIAGONAL'"]
    ) }} as postcode_coordinate_key,
    {{ bng_wgs84_coordinate_key('centroid_easting', 'centroid_northing') }}
        as coordinate_key,
    onsud_dataset_release_id,
    onsud_release_key,
    onsud_release_label,
    postcode,
    postcode_sector,
    centroid_easting,
    centroid_northing,
    distinct_point_count,
    source_allocation_tuple_count,
    conflicting_allocation_tuple_count,
    source_record_count,
    max_point_spread_m,
    'BOUNDING_BOX_DIAGONAL' as spread_method,
    'POSTCODE_CENTROID' as coordinate_method,
    '{{ var("coordinate_source_crs") }}' as source_crs,
    '{{ var("coordinate_target_crs") }}' as target_crs,
    '{{ var("coordinate_transform_contract_version") }}' as transform_contract_version,
    'postcode_coordinate_v1' as postcode_coordinate_contract_version
from centroids
