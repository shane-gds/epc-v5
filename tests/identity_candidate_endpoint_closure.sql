with current_run as (
    select identity_run_key
    from {{ ref('int_identity_current_run') }}
),

current_observations as (
    select observation.identity_run_observation_key
    from {{ ref('int_identity_observation') }} as observation
    inner join current_run
        on observation.identity_run_key = current_run.identity_run_key
),

pair_endpoints as (
    select
        'LEFT_ENDPOINT_MISSING' as issue_type,
        pair.candidate_pair_key,
        pair.run_observation_key_l as identity_run_observation_key
    from {{ ref('identity_candidate_pair') }} as pair
    inner join current_run
        on pair.identity_run_key = current_run.identity_run_key

    union all

    select
        'RIGHT_ENDPOINT_MISSING' as issue_type,
        pair.candidate_pair_key,
        pair.run_observation_key_r as identity_run_observation_key
    from {{ ref('identity_candidate_pair') }} as pair
    inner join current_run
        on pair.identity_run_key = current_run.identity_run_key
)

select
    endpoint.issue_type,
    endpoint.candidate_pair_key
from pair_endpoints as endpoint
anti join current_observations as observation
    on
        endpoint.identity_run_observation_key
        = observation.identity_run_observation_key
