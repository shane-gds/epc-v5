with selected_run as (
    select identity_run_key
    from {{ ref('int_identity_current_run') }}
),

eligible as (
    select count(*) as eligible_count
    from {{ ref('int_identity_observation') }} as observation
    inner join selected_run using (identity_run_key)
    where observation.is_identity_eligible
),

assignment_profile as (
    select
        count(*) as assignment_count,
        count(*) filter (where assignment.is_current) as current_assignment_count
    from {{ ref('bridge_source_record_entity_assignment') }} as assignment
    inner join selected_run using (identity_run_key)
)

select
    eligible.eligible_count,
    assignment_profile.assignment_count,
    assignment_profile.current_assignment_count
from eligible
cross join assignment_profile
where
    assignment_profile.assignment_count <> eligible.eligible_count
    or assignment_profile.current_assignment_count <> eligible.eligible_count
