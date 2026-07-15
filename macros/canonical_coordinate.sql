{% macro canonical_bng_coordinate_value(expression) -%}
    round(cast({{ expression }} as double), {{ var('coordinate_rounding_scale') }})
{%- endmacro %}


{% macro bng_wgs84_coordinate_key(easting_expression, northing_expression) -%}
    {% set scale = var('coordinate_rounding_scale') | string %}
    {% set canonical_easting = "cast(round(cast(" ~ easting_expression ~ " as double), " ~ scale ~ ") as decimal(12, " ~ scale ~ "))" %}
    {% set canonical_northing = "cast(round(cast(" ~ northing_expression ~ " as double), " ~ scale ~ ") as decimal(12, " ~ scale ~ "))" %}
    {{ stable_sha256(
        'epc-v4.location.coordinate-pair',
        'v3',
        [
            "'" ~ var('coordinate_source_crs') ~ "'",
            "'" ~ var('coordinate_target_crs') ~ "'",
            "'" ~ var('coordinate_transform_contract_version') ~ "'",
            "'" ~ var('coordinate_duckdb_version') ~ "'",
            "'" ~ var('coordinate_spatial_extension_version') ~ "'",
            canonical_easting,
            canonical_northing
        ]
    ) }}
{%- endmacro %}


{% macro assert_coordinate_transform_runtime() -%}
    select case
        when
            version() = '{{ var("coordinate_duckdb_version") }}'
            and (
                select extension_version
                from duckdb_extensions()
                where extension_name = 'spatial' and loaded
            ) = '{{ var("coordinate_spatial_extension_version") }}'
            then true
        else error('Coordinate transform runtime does not match the pinned contract')
    end as coordinate_runtime_valid
{%- endmacro %}
