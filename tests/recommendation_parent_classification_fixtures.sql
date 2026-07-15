-- noqa: disable=AL03
with parent_observations as (
    select
        'UNIQUE' as certificate_number,
        'UNIQUE' as certificate_conflict_status
    union all
    select
        'EXACT',
        'EXACT_DUPLICATE'
    union all
    select
        'EXACT',
        'EXACT_DUPLICATE'
    union all
    select
        'CONFLICT',
        'CONFLICT'
    union all
    select
        'CONFLICT',
        'CONFLICT'
),

parent_profile as (
    select
        certificate_number,
        count(*) filter (where certificate_conflict_status = 'CONFLICT')
            as conflicting_parent_count
    from parent_observations
    group by certificate_number
),

recommendations as (
    select
        'UNIQUE' as certificate_number,
        'MATCHED_CERTIFICATE' as expected_status
    union all
    select
        'EXACT',
        'MATCHED_CERTIFICATE'
    union all
    select
        'CONFLICT',
        'CONFLICTING_CERTIFICATE'
    union all
    select
        'ORPHAN',
        'ORPHAN_CERTIFICATE'
),

classified as (
    select
        recommendation.certificate_number,
        recommendation.expected_status,
        case
            when parent.certificate_number is null then 'ORPHAN_CERTIFICATE'
            when parent.conflicting_parent_count > 0 then 'CONFLICTING_CERTIFICATE'
            else 'MATCHED_CERTIFICATE'
        end as actual_status
    from recommendations as recommendation
    left join
        parent_profile as parent
        on recommendation.certificate_number = parent.certificate_number
)

select *
from classified
where actual_status <> expected_status
