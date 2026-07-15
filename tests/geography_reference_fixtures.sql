select
    'LAD_WELSH_NAME' as fixture_name,
    geography_code as fixture_value
from {{ ref('dim_geography') }}
where geography_type = 'LAD'
  and geography_code = 'W06000001'
  and (
      geography_name <> 'Isle of Anglesey'
      or geography_name_welsh <> 'Ynys Môn'
  )

union all

select
    'LPA_CO_TERMINOUS_TRUE',
    geography_code
from {{ ref('dim_geography') }}
where geography_type = 'LPA'
  and geography_code = 'E60000002'
  and is_co_terminous is distinct from true

union all

select
    'LPA_CO_TERMINOUS_FALSE',
    geography_code
from {{ ref('dim_geography') }}
where geography_type = 'LPA'
  and geography_code = 'E60000005'
  and is_co_terminous is distinct from false

union all

select 'MISSING_LAD_FIXTURE', null
where not exists (
    select 1
    from {{ ref('dim_geography') }}
    where geography_type = 'LAD' and geography_code = 'W06000001'
)

union all

select 'MISSING_LPA_TRUE_FIXTURE', null
where not exists (
    select 1
    from {{ ref('dim_geography') }}
    where geography_type = 'LPA' and geography_code = 'E60000002'
)

union all

select 'MISSING_LPA_FALSE_FIXTURE', null
where not exists (
    select 1
    from {{ ref('dim_geography') }}
    where geography_type = 'LPA' and geography_code = 'E60000005'
)
