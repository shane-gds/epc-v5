select table_name, column_name
from information_schema.columns
where table_schema = 'core'
  and table_name in (
      'fct_sale_transaction',
      'fct_epc_certificate',
      'fct_epc_recommendation_observation'
  )
  and (
      column_name like '%dwelling%'
      or column_name like '%building%'
      or column_name like '%registry_entity%'
      or column_name like '%subject_id%'
  )
