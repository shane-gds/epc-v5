select
    postcode_coordinate_key as coordinate_source_key,
    postcode,
    centroid_easting,
    centroid_northing,
    distinct_point_count,
    max_point_spread_m,
    coordinate_method
from {{ ref('int_postcode_coordinate') }}
where
    postcode <> {{ normalise_uk_postcode('postcode') }}
    or centroid_easting not between 0 and 700000
    or centroid_northing not between 0 and 1300000
    or distinct_point_count = 0
    or max_point_spread_m < 0
    or coordinate_method <> 'POSTCODE_CENTROID'

union all

select
    postcode_sector_coordinate_key,
    postcode_sector,
    centroid_easting,
    centroid_northing,
    unit_postcode_count,
    max_point_spread_m,
    coordinate_method
from {{ ref('int_postcode_sector_coordinate') }}
where
    centroid_easting not between 0 and 700000
    or centroid_northing not between 0 and 1300000
    or unit_postcode_count = 0
    or max_point_spread_m < 0
    or coordinate_method <> 'POSTCODE_SECTOR_CENTROID'
