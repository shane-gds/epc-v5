with candidate_count as (
    select count(*) * 2 as expected_endpoint_pairs
    from {{ ref('identity_candidate_pair') }} as candidate
    inner join {{ ref('int_identity_current_run') }} as current_run
        on candidate.identity_run_key = current_run.identity_run_key
),

alternative_count as (
    select sum(supporting_candidate_count) as actual_endpoint_pairs
    from {{ ref('identity_target_alternative') }}
)

select
    candidate_count.expected_endpoint_pairs,
    alternative_count.actual_endpoint_pairs
from candidate_count
cross join alternative_count
where candidate_count.expected_endpoint_pairs <> alternative_count.actual_endpoint_pairs
