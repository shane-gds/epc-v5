with manifest as (
    select calibration_sample_id, quota_per_stratum, sample_row_count
    from {{ source('identity_calibration', 'identity_calibration_sample_manifest') }}
    where sample_status = 'SUCCEEDED'
),

sample_counts as (
    select calibration_sample_id, count(*) as actual_row_count
    from {{ source('identity_calibration', 'identity_calibration_sample') }}
    group by calibration_sample_id
),

oversized_strata as (
    select
        sample.calibration_sample_id,
        sample.sample_stratum,
        count(*) as stratum_count,
        max(manifest.quota_per_stratum) as quota_per_stratum
    from {{ source('identity_calibration', 'identity_calibration_sample') }} as sample
    inner join manifest
        on sample.calibration_sample_id = manifest.calibration_sample_id
    group by sample.calibration_sample_id, sample.sample_stratum
    having count(*) > max(manifest.quota_per_stratum)
)

select
    'ROW_COUNT_MISMATCH' as issue_type,
    cast(manifest.calibration_sample_id as varchar) as evidence_key
from manifest
left join sample_counts
    on manifest.calibration_sample_id = sample_counts.calibration_sample_id
where manifest.sample_row_count <> coalesce(sample_counts.actual_row_count, 0)

union all

select
    'STRATUM_OVER_QUOTA',
    concat(cast(calibration_sample_id as varchar), ':', sample_stratum)
from oversized_strata
