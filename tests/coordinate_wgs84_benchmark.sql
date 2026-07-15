with independent_fixture as (
    select st_transform(
        st_point(530000, 180000),
        '{{ var("coordinate_source_crs") }}',
        '{{ var("coordinate_target_crs") }}',
        always_xy := true
    ) as transformed_point
),

independent_coordinates as (
    select
        st_x(transformed_point) as longitude,
        st_y(transformed_point) as latitude
    from independent_fixture
),

cached_fixture as (
    select
        transformed.longitude,
        transformed.latitude
    from {{ ref('int_required_coordinate_pair') }} as required
    inner join {{ ref('int_coordinate_wgs84') }} as transformed
        on required.coordinate_key = transformed.coordinate_key
    where
        required.easting = 529985.0
        and required.northing = 179952.5
)

select 'INDEPENDENT_TRANSFORM' as fixture_name, longitude, latitude
from independent_coordinates
where
    abs(longitude - (-0.12835394047946935)) > 0.000001
    or abs(latitude - 51.50399082763378) > 0.000001
    or longitude > latitude

union all

select 'CACHED_MODEL_TRANSFORM', longitude, latitude
from cached_fixture
where
    abs(longitude - (-0.12858742477613924)) > 0.000001
    or abs(latitude - 51.503567408226914) > 0.000001

union all

select 'MISSING_CACHED_FIXTURE', null, null
where not exists (select 1 from cached_fixture)
