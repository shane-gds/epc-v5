select route_selection_key
from {{ ref('int_epc_address_libpostal_route') }}
where
    numeric_designator_count < 2
    or not (has_explicit_unit_designator or has_flat_property_type)
    or parser_input is null
