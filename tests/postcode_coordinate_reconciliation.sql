with selected_release as (
    select dataset_release_id
    from {{ source('audit_ingestion', 'audit_dataset_release') }}
    where
        dataset_code = 'ONSUD'
        and release_label = '{{ var("onsud_release_label") }}'
        and status = 'LOADED'
),

source_profile as (
    select count(*) as valid_allocation_tuple_count
    from {{ ref('stg_onsud_uprn_allocation') }} as allocation
    inner join selected_release as release
        on allocation.dataset_release_id = release.dataset_release_id
    where
        allocation.postcode_parse_status = 'VALID'
        and allocation.coordinate_parse_status = 'VALID'
),

point_profile as (
    select
        count(*) as distinct_point_count,
        sum(allocation_tuple_count) as valid_allocation_tuple_count,
        count(distinct postcode) as postcode_count
    from {{ ref('int_postcode_coordinate_point') }}
),

postcode_profile as (
    select
        count(*) as postcode_count,
        sum(distinct_point_count) as distinct_point_count
    from {{ ref('int_postcode_coordinate') }}
),

sector_profile as (
    select sum(unit_postcode_count) as postcode_count
    from {{ ref('int_postcode_sector_coordinate') }}
)

select
    source_profile.valid_allocation_tuple_count as source_allocation_count,
    point_profile.valid_allocation_tuple_count as point_allocation_count,
    point_profile.distinct_point_count as point_count,
    postcode_profile.distinct_point_count as aggregated_point_count,
    point_profile.postcode_count as point_postcode_count,
    postcode_profile.postcode_count,
    sector_profile.postcode_count as sector_input_postcode_count
from source_profile
cross join point_profile
cross join postcode_profile
cross join sector_profile
where
    source_profile.valid_allocation_tuple_count <> point_profile.valid_allocation_tuple_count
    or point_profile.distinct_point_count <> postcode_profile.distinct_point_count
    or point_profile.postcode_count <> postcode_profile.postcode_count
    or postcode_profile.postcode_count <> sector_profile.postcode_count
