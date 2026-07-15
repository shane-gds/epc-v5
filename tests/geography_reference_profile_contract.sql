select
    geography_reference_profile_key,
    reference_observation_count,
    distinct_representation_count,
    reference_resolution_status
from {{ ref('int_geography_reference_profile') }}
where
    reference_observation_count < 1
    or distinct_representation_count < 1
    or distinct_representation_count > reference_observation_count
    or (
        reference_resolution_status = 'UNIQUE'
        and (reference_observation_count <> 1 or distinct_representation_count <> 1)
    )
    or (
        reference_resolution_status = 'EXACT_DUPLICATE'
        and (reference_observation_count <= 1 or distinct_representation_count <> 1)
    )
    or (
        reference_resolution_status = 'CONFLICT'
        and distinct_representation_count <= 1
    )
