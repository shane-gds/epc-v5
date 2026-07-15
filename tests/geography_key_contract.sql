select
    geography_key,
    geography_type,
    geography_code,
    geography_release_key
from {{ ref('dim_geography') }}
where geography_key is distinct from {{ stable_sha256(
    'epc-v4.geography.reference',
    'v1',
    ['geography_type', 'geography_code', 'geography_release_key']
) }}
