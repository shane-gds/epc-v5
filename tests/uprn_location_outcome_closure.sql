-- noqa: disable=AL03
with invalid_outcomes as (
    select required_uprn_key
    from {{ ref('int_uprn_location') }}
    where
        (
            location_resolution_status = 'MISSING_IN_RELEASE'
            and (
                allocation_tuple_count <> 0
                or onsud_allocation_key is not null
                or postcode is not null
                or postcode_sector is not null
                or easting is not null
                or northing is not null
                or coordinate_parse_status is not null
                or lsoa_code is not null
                or msoa_code is not null
                or lad_code is not null
                or geography_parse_status is not null
                or onsud_source_record_count is not null
                or coordinate_key is not null
                or source_crs is not null
            )
        )
        or (
            location_resolution_status = 'RESOLVED_UNIQUE'
            and (
                allocation_tuple_count <> 1
                or onsud_allocation_key is null
                or (coordinate_parse_status = 'VALID' and coordinate_key is null)
                or (coordinate_parse_status <> 'VALID' and coordinate_key is not null)
            )
        )
        or (
            location_resolution_status = 'CONFLICTING_ALLOCATIONS'
            and (
                allocation_tuple_count <= 1
                or onsud_allocation_key is not null
                or postcode is not null
                or easting is not null
                or northing is not null
                or coordinate_key is not null
            )
        )
),

missing_outcomes as (
    select required_source.required_uprn_key
    from {{ ref('int_required_uprn') }} as required_source
    left join {{ ref('int_uprn_location') }} as location_outcome
        on required_source.required_uprn_key = location_outcome.required_uprn_key
    where location_outcome.required_uprn_key is null
),

orphan_outcomes as (
    select location_outcome.required_uprn_key
    from {{ ref('int_uprn_location') }} as location_outcome
    left join {{ ref('int_required_uprn') }} as required_source
        on location_outcome.required_uprn_key = required_source.required_uprn_key
    where required_source.required_uprn_key is null
)

select
    'INVALID_OUTCOME' as issue_type,
    required_uprn_key
from invalid_outcomes
union all
select
    'MISSING_OUTCOME',
    required_uprn_key
from missing_outcomes
union all
select
    'ORPHAN_OUTCOME',
    required_uprn_key
from orphan_outcomes
