{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key=['identity_run_key', 'source_record_key'],
    on_schema_change='append_new_columns',
    tags=['identity', 'intermediate']
) }}

with ppd_source as (
    select
        *,
        nullif(
            regexp_replace(
                regexp_extract(
                    upper(paon),
                    '(^|[^A-Z0-9])([0-9]+[A-Z]?([ ]*-[ ]*[0-9]+[A-Z]?)?)[ ,.]*$',
                    2
                ),
                '[ ]+',
                '',
                'g'
            ),
            ''
        ) as paon_designator_candidate
    from {{ ref('stg_pp_transaction_observation') }}
),

ppd_observations as (
    select
        'PPD' as source_dataset,
        source_record_key,
        dataset_release_id,
        source_file_id,
        transaction_id as source_natural_key,
        transfer_date as event_date,
        address_comparison as source_address_comparison,
        {{ normalise_address(
            "concat_ws(' ', paon, saon, street, locality)"
        ) }} as premise_address_comparison,
        postcode,
        postcode_parse_status,
        cast(null as ubigint) as uprn,
        property_type,
        duration as ppd_duration,
        cast(null as varchar) as epc_tenure_observation,
        nullif(
            regexp_replace(
                regexp_replace(
                    upper(saon),
                    '^(FLAT|APARTMENT|APT|UNIT|ROOM|MAISONETTE)[ ]*',
                    ''
                ),
                '[^A-Z0-9/-]+',
                '',
                'g'
            ),
            ''
        ) as unit_identifier_comparison,
        case
            when
                not contains(paon, '/')
                and paon_designator_candidate is not null
                and len(regexp_extract_all(upper(paon), '[0-9]+'))
                = case when contains(paon_designator_candidate, '-') then 2 else 1 end
                then paon_designator_candidate
        end as building_number_designator,
        {{ normalise_address('street') }} as road_comparison,
        'PPD_STRUCTURED_FIELDS' as address_component_method,
        cast(null as varchar) as address_parse_result_key,
        cast(null as varchar) as address_parse_selection_reason,
        cast(null as varchar) as address_parser_contract_version
    from ppd_source
),

epc_observations as (
    select
        'EPC_CERTIFICATE' as source_dataset,
        epc.source_record_key,
        epc.dataset_release_id,
        epc.source_file_id,
        epc.certificate_number as source_natural_key,
        epc.inspection_date as event_date,
        epc.address_comparison as source_address_comparison,
        {{ normalise_address(
            "concat_ws(' ', epc.address1, epc.address2, epc.address3)"
        ) }} as premise_address_comparison,
        epc.postcode,
        epc.postcode_parse_status,
        epc.uprn,
        epc.property_type,
        cast(null as varchar) as ppd_duration,
        epc.tenure_observation as epc_tenure_observation,
        address_parse.unit_identifier_comparison,
        address_parse.building_number_designator,
        address_parse.road_comparison,
        case
            when address_parse.source_record_key is null then 'NOT_ROUTED'
            else 'LIBPOSTAL'
        end as address_component_method,
        address_parse.address_parse_result_key,
        address_parse.selection_reason as address_parse_selection_reason,
        address_parse.parser_contract_version as address_parser_contract_version
    from {{ ref('stg_epc_certificate_observation') }} as epc
    left join {{ ref('int_identity_address_parse') }} as address_parse
        on epc.source_record_key = address_parse.source_record_key
),

observations as (
    select *
    from ppd_observations

    union all

    select *
    from epc_observations
),

classified as (
    select
        *,
        nullif(
            regexp_extract(premise_address_comparison, '(^| )([0-9]+[A-Z]?)', 2),
            ''
        ) as premise_number_token,
        case
            when address_component_method = 'NOT_ROUTED' then 'NOT_ROUTED'
            when
                unit_identifier_comparison is not null
                and building_number_designator is not null
                and road_comparison is not null
                then 'COMPLETE'
            else 'INCOMPLETE'
        end as address_component_status,
        case
            when premise_address_comparison is null then 'INELIGIBLE_MISSING_ADDRESS'
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
        ['source_dataset', 'source_record_key']
    ) }} as identity_observation_key,
    {{ stable_sha256(
        'epc-v4.identity.run-observation',
        'v1',
        ['identity_run_key', 'source_dataset', 'source_record_key']
    ) }} as identity_run_observation_key,
    identity_run_id,
    identity_run_key,
    source_dataset,
    source_record_key,
    dataset_release_id,
    source_file_id,
    source_natural_key,
    event_date,
    source_address_comparison,
    premise_address_comparison,
    premise_number_token,
    '{{ var("identity_address_normaliser_version") }}' as normaliser_version,
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
    unit_identifier_comparison,
    building_number_designator,
    road_comparison,
    address_component_method,
    address_component_status,
    address_parse_result_key,
    address_parse_selection_reason,
    address_parser_contract_version,
    '{{ var("identity_address_component_contract_version") }}'
        as address_component_contract_version,
    eligibility_status,
    eligibility_status = 'ELIGIBLE' as is_identity_eligible,
    '{{ var("identity_input_algorithm_version") }}' as identity_population_contract_version
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
