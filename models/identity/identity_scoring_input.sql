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
    observation.postcode,
    observation.postcode_sector,
    cast(observation.uprn as varchar) as uprn,
    observation.event_date,
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
where observation.is_identity_eligible
