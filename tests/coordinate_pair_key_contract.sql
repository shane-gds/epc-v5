select
    coordinate_key,
    easting,
    northing,
    source_crs,
    target_crs,
    transform_contract_version
from {{ ref('int_required_coordinate_pair') }}
where
    coordinate_key is distinct from {{ bng_wgs84_coordinate_key('easting', 'northing') }}
    or source_crs is distinct from '{{ var("coordinate_source_crs") }}'
    or target_crs is distinct from '{{ var("coordinate_target_crs") }}'
    or transform_contract_version
        is distinct from '{{ var("coordinate_transform_contract_version") }}'
    or (validation_status = 'VALID' and (
        easting not between 0 and 700000 or northing not between 0 and 1300000
    ))
