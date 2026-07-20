{{ config(materialized='table', tags=['silver', 'address_parsing']) }}

with epc_addresses as (
    select
        source_record_key,
        dataset_release_id,
        source_file_id,
        source_row_number,
        address1,
        address2,
        address3,
        posttown,
        postcode,
        postcode_parse_status,
        property_type,
        concat_ws(' ', address1, address2, address3) as address_text,
        concat_ws(
            ', ',
            address1,
            address2,
            address3,
            posttown,
            postcode,
            'United Kingdom'
        ) as parser_input
    from {{ ref('stg_epc_certificate_observation') }}
),

profiled as (
    select
        *,
        len(
            regexp_extract_all(
                upper(address_text),
                '[0-9]+[A-Z]?'
            )
        ) as numeric_designator_count,
        regexp_matches(
            upper(address_text),
            '(^|[^A-Z0-9])(FLAT|APARTMENT|APT|UNIT|ROOM|MAISONETTE)[ ]*[0-9]+[A-Z]?'
        ) as has_explicit_unit_designator,
        lower(coalesce(property_type, '')) like '%flat%'
        or lower(coalesce(property_type, '')) like '%maisonette%'
            as has_flat_property_type
    from epc_addresses
    where
        address_text is not null
        and postcode_parse_status = 'VALID'
),

routed as (
    select
        *,
        case
            when has_explicit_unit_designator then 'EXPLICIT_UNIT_MULTI_NUMBER'
            else 'FLAT_PROPERTY_MULTI_NUMBER'
        end as selection_reason
    from profiled
    where
        numeric_designator_count >= 2
        and (has_explicit_unit_designator or has_flat_property_type)
),

keyed as (
    select
        *,
        {{ stable_sha256(
            'epc-v5.identity.address-parser-input',
            'v1',
            [
                "'" ~ var('identity_libpostal_input_contract_version') ~ "'",
                'parser_input'
            ]
        ) }} as parser_input_key
    from routed
)

select
    {{ stable_sha256(
        'epc-v5.identity.address-parser-route',
        'v1',
        [
            "'" ~ var('identity_address_selector_contract_version') ~ "'",
            'source_record_key',
            'parser_input_key',
            'selection_reason'
        ]
    ) }} as route_selection_key,
    source_record_key,
    dataset_release_id,
    source_file_id,
    source_row_number,
    parser_input_key,
    parser_input,
    selection_reason,
    numeric_designator_count,
    has_explicit_unit_designator,
    has_flat_property_type,
    '{{ var("identity_address_selector_contract_version") }}'
        as selector_contract_version,
    '{{ var("identity_libpostal_input_contract_version") }}'
        as parser_input_contract_version
from keyed
