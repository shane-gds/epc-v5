{{ config(materialized='table', tags=['identity', 'calibration']) }}

with current_observations as (
    select observation.*
    from {{ ref('int_identity_observation') }} as observation
    inner join {{ ref('int_identity_current_run') }} as current_run
        on observation.identity_run_key = current_run.identity_run_key
    where observation.is_identity_eligible
)

select
    case
        when source_dataset = 'EPC_CERTIFICATE' and uprn is not null then {{ stable_sha256(
            'epc-v4.identity.target-hypothesis',
            'v1',
            ['identity_run_key', "'SUPPLIED_UPRN'", 'cast(uprn as varchar)']
        ) }}
        else {{ stable_sha256(
            'epc-v4.identity.target-hypothesis',
            'v1',
            [
                'identity_run_key',
                "'ADDRESS_SIGNATURE'",
                'postcode',
                'premise_address_comparison'
            ]
        ) }}
    end as target_hypothesis_key,
    identity_run_id,
    identity_run_key,
    identity_run_observation_key,
    identity_observation_key,
    source_dataset,
    event_date,
    case
        when source_dataset = 'EPC_CERTIFICATE' and uprn is not null then 'SUPPLIED_UPRN'
        else 'ADDRESS_SIGNATURE'
    end as target_hypothesis_type,
    case
        when source_dataset = 'EPC_CERTIFICATE' and uprn is not null
            then cast(uprn as varchar)
        else concat_ws('|', postcode, premise_address_comparison)
    end as target_hypothesis_value,
    'EVIDENCE_GROUP_ONLY' as target_hypothesis_status,
    '{{ var("identity_decision_policy_version") }}' as decision_policy_version
from current_observations
