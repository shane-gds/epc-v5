{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key=['identity_run_key', 'source_record_key'],
    tags=['identity', 'intermediate']
) }}

with observations as (
    select
        'PPD' as source_dataset,
        source_record_key,
        dataset_release_id,
        source_file_id,
        transaction_id as source_natural_key,
        transfer_date as event_date,
        address_comparison,
        normaliser_version,
        postcode,
        postcode_parse_status,
        cast(null as ubigint) as uprn,
        property_type,
        duration as ppd_duration,
        cast(null as varchar) as epc_tenure_observation
    from {{ ref('stg_pp_transaction_observation') }}

    union all

    select
        'EPC_CERTIFICATE' as source_dataset,
        source_record_key,
        dataset_release_id,
        source_file_id,
        certificate_number as source_natural_key,
        inspection_date as event_date,
        address_comparison,
        normaliser_version,
        postcode,
        postcode_parse_status,
        uprn,
        property_type,
        cast(null as varchar) as ppd_duration,
        tenure_observation as epc_tenure_observation
    from {{ ref('stg_epc_certificate_observation') }}
),

classified as (
    select
        *,
        case
            when address_comparison is null then 'INELIGIBLE_MISSING_ADDRESS'
            when postcode_parse_status = 'MISSING' then 'INELIGIBLE_MISSING_POSTCODE'
            when postcode_parse_status = 'INVALID' then 'INELIGIBLE_INVALID_POSTCODE'
            else 'ELIGIBLE'
        end as eligibility_status
    from observations
),

run_population as (
    select
        classified.*,
        current_run.identity_run_id,
        current_run.identity_run_key
    from classified
    cross join {{ ref('int_identity_current_run') }} as current_run
)

select
    {{ stable_sha256(
        'epc-v4.identity.observation',
        'v1',
        ['identity_run_key', 'source_dataset', 'source_record_key']
    ) }} as identity_observation_key,
    identity_run_id,
    identity_run_key,
    source_dataset,
    source_record_key,
    dataset_release_id,
    source_file_id,
    source_natural_key,
    event_date,
    address_comparison,
    normaliser_version,
    postcode,
    case
        when postcode is null then null
        else concat(split_part(postcode, ' ', 1), ' ', left(split_part(postcode, ' ', 2), 1))
    end as postcode_sector,
    postcode_parse_status,
    uprn,
    property_type,
    ppd_duration,
    epc_tenure_observation,
    eligibility_status,
    eligibility_status = 'ELIGIBLE' as is_identity_eligible,
    'identity_population_v1' as identity_population_contract_version
from run_population
{% if is_incremental() %}
    where not exists (
        select 1
        from {{ this }} as existing_observation
        where
            existing_observation.identity_run_key = run_population.identity_run_key
            and existing_observation.source_record_key = run_population.source_record_key
    )
{% endif %}
