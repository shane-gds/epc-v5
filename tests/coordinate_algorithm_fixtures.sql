select
    'UNIT_POSTCODE_DISTINCT_POINT_WEIGHTING' as fixture_name,
    postcode as fixture_value
from {{ ref('int_postcode_coordinate') }}
where postcode = 'AB10 1AG'
  and (
      distinct_point_count <> 2
      or source_allocation_tuple_count <> 3
      or abs(centroid_easting - 394240.0) > 0.000001
      or abs(centroid_northing - 806422.5) > 0.000001
      or abs(max_point_spread_m - 95.12623192369179) > 0.000001
  )

union all

select
    'POSTCODE_SECTOR_EQUAL_WEIGHTING',
    postcode_sector
from {{ ref('int_postcode_sector_coordinate') }}
where postcode_sector = 'AB10 1'
  and (
      unit_postcode_count <> 193
      or abs(centroid_easting - 393614.552) > 0.000001
      or abs(centroid_northing - 805984.722) > 0.000001
      or abs(max_point_spread_m - 4803.414513436139) > 0.000001
  )

union all

select 'MISSING_UNIT_POSTCODE_FIXTURE', null
where not exists (
    select 1 from {{ ref('int_postcode_coordinate') }} where postcode = 'AB10 1AG'
)

union all

select 'MISSING_SECTOR_FIXTURE', null
where not exists (
    select 1 from {{ ref('int_postcode_sector_coordinate') }} where postcode_sector = 'AB10 1'
)
