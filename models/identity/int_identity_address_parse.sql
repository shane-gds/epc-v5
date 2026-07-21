{{ config(materialized='view', tags=['identity', 'address_parsing']) }}

select
    request.source_record_key,
    request.route_selection_key,
    request.address_parse_request_key,
    result.address_parse_result_key,
    current_run.address_parse_run_id,
    current_run.address_parse_run_key,
    current_run.parser_contract_version,
    current_run.runtime_artifact_key,
    current_run.parser_implementation_sha256,
    request.selection_reason,
    result.building_number_designator,
    result.unit_identifier_comparison,
    result.road_comparison,
    result.parse_status,
    result.parse_error
from {{ ref('int_identity_current_run') }} as current_run
inner join {{ source('identity_address_parser', 'identity_address_parse_request') }} as request
    on current_run.address_parse_run_key = request.address_parse_run_key
inner join {{ source('identity_address_parser', 'identity_address_parse_result') }} as result
    on request.address_parse_result_key = result.address_parse_result_key
