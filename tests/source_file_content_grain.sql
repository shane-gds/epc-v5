select
    dataset_release_id,
    content_sha256,
    count(*) as manifest_count
from {{ source('audit_ingestion', 'audit_source_file') }}
group by dataset_release_id, content_sha256
having count(*) > 1
