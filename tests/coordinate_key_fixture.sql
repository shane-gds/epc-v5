with fixture as (
    select {{ bng_wgs84_coordinate_key('530000.0', '180000.0') }} as coordinate_key
)

select coordinate_key
from fixture
where coordinate_key <> 'e1318df2b4e77b7556720fa0635bbec3d535adb0df0f1f14fc20d54a2ca76c2c'
