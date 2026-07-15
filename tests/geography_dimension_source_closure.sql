with publishable_profiles as (
    select geography_reference_profile_key
    from {{ ref('int_geography_reference_profile') }}
    where reference_resolution_status <> 'CONFLICT'
),

missing_dimension_rows as (
    select profile.geography_reference_profile_key
    from publishable_profiles as profile
    left join {{ ref('dim_geography') }} as geography
        on profile.geography_reference_profile_key = geography.geography_reference_profile_key
    where geography.geography_reference_profile_key is null
),

orphan_dimension_rows as (
    select geography.geography_reference_profile_key
    from {{ ref('dim_geography') }} as geography
    left join publishable_profiles as profile
        on geography.geography_reference_profile_key = profile.geography_reference_profile_key
    where profile.geography_reference_profile_key is null
)

select 'MISSING_DIMENSION_ROW' as issue_type, geography_reference_profile_key
from missing_dimension_rows
union all
select 'ORPHAN_DIMENSION_ROW', geography_reference_profile_key
from orphan_dimension_rows
