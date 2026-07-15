with fixture as (
    select {{ bng_wgs84_coordinate_key('530000.0', '180000.0') }} as coordinate_key
)

select coordinate_key
from fixture
where coordinate_key <> '9dfe8b238220f8e0e0edeb011b132600985eec69aaa10ed29e0d2c1991596d03'
