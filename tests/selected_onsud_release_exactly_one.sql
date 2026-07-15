select count(*) as selected_release_count
from {{ source('audit_ingestion', 'audit_dataset_release') }}
where
    dataset_code = 'ONSUD'
    and release_label = '{{ var("onsud_release_label") }}'
    and status = 'LOADED'
having count(*) <> 1
