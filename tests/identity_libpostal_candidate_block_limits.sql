select candidate_block_key
from {{ ref('identity_libpostal_candidate_block_profile') }}
where
    is_admitted
    and (
        ppd_side_count > maximum_side_count
        or epc_side_count > maximum_side_count
        or candidate_pair_product > maximum_pair_product
    )
