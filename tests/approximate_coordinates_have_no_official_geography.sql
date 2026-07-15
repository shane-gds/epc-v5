select table_name, column_name
from information_schema.columns
where table_schema = 'core'
  and table_name in ('int_postcode_coordinate', 'int_postcode_sector_coordinate')
  and (
      column_name like '%lsoa%'
      or column_name like '%msoa%'
      or column_name like '%lad%'
      or column_name like '%region%'
      or column_name like '%country%'
      or column_name like '%geography%'
  )
