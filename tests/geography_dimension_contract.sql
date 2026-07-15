select
    geography_key,
    geography_type,
    geography_code,
    geography_name,
    parent_geography_key,
    country_code,
    valid_from,
    valid_to,
    hierarchy_status,
    country_assignment_status,
    validity_status
from {{ ref('dim_geography') }}
where
    not regexp_full_match(geography_code, '^[ENSW][0-9]{8}$')
    or geography_name <> trim(geography_name)
    or geography_name = ''
    or parent_geography_key is not null
    or country_code is not null
    or valid_from is not null
    or valid_to is not null
    or hierarchy_status <> 'NOT_SUPPLIED'
    or country_assignment_status <> 'NOT_SUPPLIED'
    or validity_status <> 'NOT_SUPPLIED'
    or is_current_release is distinct from case
        when geography_type = 'LAD'
            then geography_release_label = '{{ var("lad_reference_release_label") }}'
        when geography_type = 'LPA'
            then geography_release_label = '{{ var("lpa_reference_release_label") }}'
        else false
    end
    or (geography_type = 'LAD' and co_terminous_status <> 'NOT_APPLICABLE')
    or (geography_type = 'LPA' and co_terminous_status <> 'VALID')
