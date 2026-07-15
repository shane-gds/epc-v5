with invalid_transforms as (
    select transformed.coordinate_key
    from {{ ref('int_coordinate_wgs84') }} as transformed
    inner join {{ ref('int_required_coordinate_pair') }} as required
        on transformed.coordinate_key = required.coordinate_key
    where
        required.validation_status <> 'VALID'
        or transformed.longitude not between -180 and 180
        or transformed.latitude not between -90 and 90
        or transformed.transform_contract_version <> required.transform_contract_version
),

missing_transforms as (
    select required.coordinate_key
    from {{ ref('int_required_coordinate_pair') }} as required
    left join {{ ref('int_coordinate_wgs84') }} as transformed
        on required.coordinate_key = transformed.coordinate_key
    where required.validation_status = 'VALID' and transformed.coordinate_key is null
)

select 'INVALID_TRANSFORM' as issue_type, coordinate_key
from invalid_transforms
union all
select 'MISSING_TRANSFORM', coordinate_key
from missing_transforms
