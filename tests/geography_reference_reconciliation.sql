with source_counts as (
    select 'LAD' as geography_type, count(*) as source_count
    from {{ source('bronze_ingestion', 'raw_lad_name_code') }}
    union all
    select 'LPA', count(*)
    from {{ source('bronze_ingestion', 'raw_lpa_name_code') }}
),

staging_counts as (
    select
        'LAD' as geography_type,
        count(*) as staging_count,
        count(*) filter (where geography_parse_status = 'VALID') as valid_count
    from {{ ref('stg_lad_name_code_reference') }}
    union all
    select
        'LPA',
        count(*),
        count(*) filter (where geography_parse_status = 'VALID')
    from {{ ref('stg_lpa_name_code_reference') }}
),

dimension_counts as (
    select geography_type, count(*) as dimension_count
    from {{ ref('dim_geography') }}
    group by geography_type
),

profile_counts as (
    select
        geography_type,
        count(*) filter (where reference_resolution_status <> 'CONFLICT')
            as publishable_profile_count
    from {{ ref('int_geography_reference_profile') }}
    group by geography_type
)

select
    source_counts.geography_type,
    source_counts.source_count,
    staging_counts.staging_count,
    staging_counts.valid_count,
    profile_counts.publishable_profile_count,
    dimension_counts.dimension_count
from source_counts
inner join staging_counts using (geography_type)
inner join dimension_counts using (geography_type)
inner join profile_counts using (geography_type)
where
    source_counts.source_count <> staging_counts.staging_count
    or profile_counts.publishable_profile_count <> dimension_counts.dimension_count
