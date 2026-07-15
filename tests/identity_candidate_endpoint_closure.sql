with current_observations as (
    select identity_run_observation_key
    from {{ ref('int_identity_observation') }} as observation
    inner join {{ ref('int_identity_current_run') }} as current_run
        on observation.identity_run_key = current_run.identity_run_key
),

current_pairs as (
    select pair.*
    from {{ ref('identity_candidate_pair') }} as pair
    inner join {{ ref('int_identity_current_run') }} as current_run
        on pair.identity_run_key = current_run.identity_run_key
)

select
    'LEFT_ENDPOINT_MISSING' as issue_type,
    pair.candidate_pair_key
from current_pairs as pair
left join current_observations as observation
    on pair.run_observation_key_l = observation.identity_run_observation_key
where observation.identity_run_observation_key is null

union all

select
    'RIGHT_ENDPOINT_MISSING',
    pair.candidate_pair_key
from current_pairs as pair
left join current_observations as observation
    on pair.run_observation_key_r = observation.identity_run_observation_key
where observation.identity_run_observation_key is null
