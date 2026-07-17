{{ config(materialized='view', tags=['identity', 'splink']) }}

select
    observation.identity_run_observation_key as unique_id,
    observation.identity_run_id,
    observation.identity_run_key,
    observation.identity_observation_key,
    observation.source_dataset,
    observation.source_natural_key,
    observation.premise_address_comparison,
    observation.premise_number_token,
    observation.unit_identifier_comparison,
    observation.building_number_designator,
    observation.road_comparison,
    observation.address_component_method,
    observation.address_component_status,
    observation.postcode,
    observation.postcode_sector,
    cast(observation.uprn as varchar) as uprn,
    observation.event_date,
    coalesce(candidate_block.block_status, 'NOT_APPLICABLE')
        as libpostal_candidate_block_status,
    case
        when observation.source_dataset = 'PPD'
            then case observation.property_type
                when 'D' then 'HOUSE'
                when 'S' then 'HOUSE'
                when 'T' then 'HOUSE'
                when 'F' then 'FLAT'
                else 'OTHER'
            end
        when
            lower(observation.property_type) like '%flat%'
            or lower(observation.property_type) like '%maisonette%' then 'FLAT'
        when
            lower(observation.property_type) like '%house%'
            or lower(observation.property_type) like '%bungalow%'
            or lower(observation.property_type) like '%park home%' then 'HOUSE'
        else 'OTHER'
    end as property_class
from {{ ref('int_identity_observation') }} as observation
inner join {{ ref('int_identity_current_run') }} as current_run
    on observation.identity_run_key = current_run.identity_run_key
left join {{ ref('identity_libpostal_candidate_block_profile') }} as candidate_block
    on
        observation.identity_run_key = candidate_block.identity_run_key
        and observation.postcode = candidate_block.postcode
        and observation.unit_identifier_comparison
        = candidate_block.unit_identifier_comparison
        and observation.building_number_designator
        = candidate_block.building_number_designator
where observation.is_identity_eligible
