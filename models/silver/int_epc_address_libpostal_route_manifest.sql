{{ config(materialized='table', tags=['silver', 'address_parsing']) }}

select
    '{{ var("identity_address_selector_contract_version") }}'
        as selector_contract_version,
    '{{ var("identity_libpostal_input_contract_version") }}'
        as parser_input_contract_version,
    count(*) as routed_observation_count,
    count(distinct parser_input_key) as distinct_parser_input_count,
    {{ stable_sha256(
        'epc-v4.identity.address-parser-route-population',
        'v1',
        [
            "'" ~ var('identity_address_selector_contract_version') ~ "'",
            "'" ~ var('identity_libpostal_input_contract_version') ~ "'",
            'cast(count(*) as varchar)',
            "coalesce(sha256(string_agg(route_selection_key, '' order by route_selection_key)), sha256(''))"
        ]
    ) }} as route_population_fingerprint,
    current_timestamp as calculated_at
from {{ ref('int_epc_address_libpostal_route') }}
