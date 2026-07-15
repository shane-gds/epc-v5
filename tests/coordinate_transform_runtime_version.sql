with runtime as (
    select
        version() as duckdb_version,
        extension_version as spatial_extension_version
    from duckdb_extensions()
    where extension_name = 'spatial' and loaded
)

select duckdb_version, spatial_extension_version
from runtime
where
    duckdb_version <> '{{ var("coordinate_duckdb_version") }}'
    or spatial_extension_version <> '{{ var("coordinate_spatial_extension_version") }}'

union all

select null, null
where not exists (select 1 from runtime)
