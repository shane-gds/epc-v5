{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='coordinate_key',
    on_schema_change='append_new_columns',
    pre_hook=assert_coordinate_transform_runtime(),
    tags=['core', 'intermediate', 'location', 'coordinate-cache']
) }}

with required_pairs as (
    select required_pair.*
    from {{ ref('int_required_coordinate_pair') }} as required_pair
    where
        required_pair.validation_status = 'VALID'
        {% if is_incremental() %}
            and not exists (
                select 1
                from {{ this }} as transformed
                where transformed.coordinate_key = required_pair.coordinate_key
            )
        {% endif %}
),

transformed as (
    select
        *,
        st_transform(
            st_point(easting, northing),
            source_crs,
            target_crs,
            always_xy := true
        ) as wgs84_point
    from required_pairs
),

coordinates as (
    select
        *,
        st_x(wgs84_point) as longitude,
        st_y(wgs84_point) as latitude
    from transformed
),

spatial_version as (
    select extension_version
    from duckdb_extensions()
    where extension_name = 'spatial' and loaded
)

select
    coordinates.coordinate_key,
    coordinates.longitude,
    coordinates.latitude,
    coordinates.wgs84_point,
    coordinates.source_crs,
    coordinates.target_crs,
    coordinates.transform_contract_version,
    spatial_version.extension_version as spatial_extension_version,
    'coordinate_wgs84_v1' as coordinate_wgs84_contract_version,
    version() as duckdb_version,
    case
        when
            coordinates.longitude between -9.0 and 3.0
            and coordinates.latitude between 49.0 and 61.5 then 'VALID'
        else 'OUT_OF_EXPECTED_BOUNDS'
    end as transform_status,
    current_timestamp as transformed_at
from coordinates
cross join spatial_version
