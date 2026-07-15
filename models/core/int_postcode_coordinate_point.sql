{{ config(materialized='table', tags=['core', 'intermediate', 'location', 'support']) }}

with selected_onsud_release as (
    select
        dataset_release_id,
        release_key,
        release_label
    from {{ source('audit_ingestion', 'audit_dataset_release') }}
    where
        dataset_code = 'ONSUD'
        and release_label = '{{ var("onsud_release_label") }}'
        and status = 'LOADED'
)

select
    {{ stable_sha256(
        'epc-v4.location.postcode-coordinate-point',
        'v1',
        [
            'onsud_release.release_key',
            'allocation.postcode',
            'cast(allocation.easting as varchar)',
            'cast(allocation.northing as varchar)'
        ]
    ) }} as postcode_coordinate_point_key,
    onsud_release.dataset_release_id as onsud_dataset_release_id,
    onsud_release.release_key as onsud_release_key,
    onsud_release.release_label as onsud_release_label,
    allocation.postcode,
    allocation.postcode_sector,
    allocation.easting,
    allocation.northing,
    count(*)::uinteger as allocation_tuple_count,
    count(*) filter (where allocation.allocation_status = 'CONFLICT')::uinteger
        as conflicting_allocation_tuple_count,
    sum(allocation.source_record_count)::ubigint as source_record_count,
    'postcode_coordinate_point_v1' as point_contract_version
from {{ ref('stg_onsud_uprn_allocation') }} as allocation
inner join selected_onsud_release as onsud_release
    on allocation.dataset_release_id = onsud_release.dataset_release_id
where
    allocation.postcode_parse_status = 'VALID'
    and allocation.coordinate_parse_status = 'VALID'
group by
    onsud_release.dataset_release_id,
    onsud_release.release_key,
    onsud_release.release_label,
    allocation.postcode,
    allocation.postcode_sector,
    allocation.easting,
    allocation.northing
