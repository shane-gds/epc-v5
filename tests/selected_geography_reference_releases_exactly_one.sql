with expected as (
    select 'ONS_LAD_NAMES_CODES' as dataset_code, '{{ var("lad_reference_release_label") }}'
        as release_label
    union all
    select 'ONS_LPA_NAMES_CODES', '{{ var("lpa_reference_release_label") }}'
),

actual as (
    select
        expected.dataset_code,
        expected.release_label,
        count(release.dataset_release_id) as loaded_release_count
    from expected
    left join {{ source('audit_ingestion', 'audit_dataset_release') }} as release
        on
            expected.dataset_code = release.dataset_code
            and expected.release_label = release.release_label
            and release.status = 'LOADED'
    group by expected.dataset_code, expected.release_label
)

select dataset_code, release_label, loaded_release_count
from actual
where loaded_release_count <> 1
