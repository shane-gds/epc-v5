with invalid_membership as (
    select membership.source_file_container_key
    from {{ source('audit_ingestion', 'audit_source_file_container') }} as membership
    inner join {{ source('audit_ingestion', 'audit_source_file') }} as parent
        on membership.parent_source_file_id = parent.source_file_id
    inner join {{ source('audit_ingestion', 'audit_source_file') }} as child
        on membership.child_source_file_id = child.source_file_id
    where
        parent.file_kind <> 'ZIP_ARCHIVE'
        or child.file_kind <> 'ZIP_MEMBER_CSV'
        or parent.dataset_release_id <> child.dataset_release_id
),

missing_membership as (
    select child.source_file_id
    from {{ source('audit_ingestion', 'audit_source_file') }} as child
    left join {{ source('audit_ingestion', 'audit_source_file_container') }} as membership
        on child.source_file_id = membership.child_source_file_id
    where child.file_kind = 'ZIP_MEMBER_CSV'
      and membership.child_source_file_id is null
)

select 'INVALID_MEMBERSHIP' as issue_type, source_file_container_key as evidence_key
from invalid_membership
union all
select 'MISSING_MEMBERSHIP', cast(source_file_id as varchar)
from missing_membership
