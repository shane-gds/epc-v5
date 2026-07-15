with eligible as (
    select
        count(*) as observation_count,
        bit_xor(hash(observation.identity_run_observation_key)) as endpoint_checksum
    from {{ ref('int_identity_observation') }} as observation
    inner join {{ ref('int_identity_current_run') }} as current_run
        on observation.identity_run_key = current_run.identity_run_key
    where observation.is_identity_eligible
),

target_hypotheses as (
    select
        count(*) as observation_count,
        bit_xor(hash(target.identity_run_observation_key)) as endpoint_checksum
    from {{ ref('identity_target_hypothesis') }} as target
)

select
    eligible.observation_count as expected_observation_count,
    target_hypotheses.observation_count as actual_observation_count,
    eligible.endpoint_checksum as expected_endpoint_checksum,
    target_hypotheses.endpoint_checksum as actual_endpoint_checksum
from eligible
cross join target_hypotheses
where
    eligible.observation_count <> target_hypotheses.observation_count
    or eligible.endpoint_checksum <> target_hypotheses.endpoint_checksum
