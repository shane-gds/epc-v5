with source_coordinates as (
    select coordinate_key
    from {{ ref('int_uprn_location') }}
    where
        location_resolution_status = 'RESOLVED_UNIQUE'
        and coordinate_parse_status = 'VALID'

    union

    select coordinate_key
    from {{ ref('int_postcode_coordinate') }}

    union

    select coordinate_key
    from {{ ref('int_postcode_sector_coordinate') }}
),

missing_pairs as (
    select source.coordinate_key
    from source_coordinates as source
    left join {{ ref('int_required_coordinate_pair') }} as required
        on source.coordinate_key = required.coordinate_key
    where required.coordinate_key is null
)

select 'MISSING_PAIR' as issue_type, coordinate_key
from missing_pairs
