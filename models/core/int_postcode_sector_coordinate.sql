{{ config(materialized='table', tags=['core', 'intermediate', 'location']) }}

with sector_centroids as (
    select
        onsud_dataset_release_id,
        onsud_release_key,
        onsud_release_label,
        postcode_sector,
        {{ canonical_bng_coordinate_value('avg(centroid_easting)') }} as centroid_easting,
        {{ canonical_bng_coordinate_value('avg(centroid_northing)') }} as centroid_northing,
        count(*)::uinteger as unit_postcode_count,
        sum(distinct_point_count)::ubigint as source_distinct_point_count,
        sqrt(
            power(max(centroid_easting) - min(centroid_easting), 2)
            + power(max(centroid_northing) - min(centroid_northing), 2)
        )::double as max_point_spread_m
    from {{ ref('int_postcode_coordinate') }}
    group by
        onsud_dataset_release_id,
        onsud_release_key,
        onsud_release_label,
        postcode_sector
)

select
    {{ stable_sha256(
        'epc-v5.location.postcode-sector-coordinate',
        'v1',
        [
            'onsud_release_key',
            'postcode_sector',
            "'POSTCODE_SECTOR_CENTROID'",
            "'UNIT_POSTCODE_EQUAL_WEIGHT'",
            "'BOUNDING_BOX_DIAGONAL'"
        ]
    ) }} as postcode_sector_coordinate_key,
    {{ bng_wgs84_coordinate_key('centroid_easting', 'centroid_northing') }}
        as coordinate_key,
    onsud_dataset_release_id,
    onsud_release_key,
    onsud_release_label,
    postcode_sector,
    centroid_easting,
    centroid_northing,
    unit_postcode_count,
    source_distinct_point_count,
    max_point_spread_m,
    'UNIT_POSTCODE_EQUAL_WEIGHT' as centroid_weighting_method,
    'BOUNDING_BOX_DIAGONAL' as spread_method,
    'POSTCODE_SECTOR_CENTROID' as coordinate_method,
    '{{ var("coordinate_source_crs") }}' as source_crs,
    '{{ var("coordinate_target_crs") }}' as target_crs,
    '{{ var("coordinate_transform_contract_version") }}' as transform_contract_version,
    'postcode_sector_coordinate_v1' as postcode_sector_coordinate_contract_version
from sector_centroids
