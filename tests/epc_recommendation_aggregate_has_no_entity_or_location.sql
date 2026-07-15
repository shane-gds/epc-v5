select table_name, column_name
from information_schema.columns
where table_schema = 'core'
  and table_name = 'int_epc_recommendation_agg'
  and (
      column_name like '%dwelling%'
      or column_name like '%building%'
      or column_name like '%registry%'
      or column_name like '%longitude%'
      or column_name like '%latitude%'
      or column_name like '%geography%'
  )
