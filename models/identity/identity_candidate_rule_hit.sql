-- noqa: disable=AL03,RF04
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='candidate_rule_hit_key',
    on_schema_change='append_new_columns',
    tags=['identity', 'candidate_generation']
) }}

with current_run as (
    select
        identity_run_id,
        identity_run_key,
        blocking_policy_version
    from {{ ref('int_identity_current_run') }}
),

observations as (
    select observation.*
    from {{ ref('int_identity_observation') }} as observation
    inner join current_run
        on observation.identity_run_key = current_run.identity_run_key
    where observation.is_identity_eligible
),

enabled_policy as (
    select policy.*
    from {{ ref('identity_blocking_policy') }} as policy
    inner join current_run
        on policy.policy_version = current_run.blocking_policy_version
    where policy.enabled
),

raw_rule_hits as (
    select
        left_observation.identity_run_id,
        left_observation.identity_run_key,
        left_observation.identity_run_observation_key as run_observation_key_l,
        right_observation.identity_run_observation_key as run_observation_key_r,
        left_observation.identity_observation_key as observation_key_l,
        right_observation.identity_observation_key as observation_key_r,
        policy.policy_version,
        policy.rule_code,
        policy.rule_logic_version,
        policy.rule_priority,
        policy.evidence_class,
        policy.source_pair_scope
    from observations as left_observation
    inner join observations as right_observation
        on
            left_observation.uprn = right_observation.uprn
            and left_observation.identity_run_observation_key
            < right_observation.identity_run_observation_key
            and left_observation.source_dataset = 'EPC_CERTIFICATE'
            and right_observation.source_dataset = 'EPC_CERTIFICATE'
    inner join enabled_policy as policy
        on policy.rule_code = 'D01_EXACT_UPRN'
    where left_observation.uprn is not null

    union all

    select
        pp.identity_run_id,
        pp.identity_run_key,
        least(pp.identity_run_observation_key, epc.identity_run_observation_key),
        greatest(pp.identity_run_observation_key, epc.identity_run_observation_key),
        case
            when pp.identity_run_observation_key < epc.identity_run_observation_key
                then pp.identity_observation_key
            else epc.identity_observation_key
        end,
        case
            when pp.identity_run_observation_key < epc.identity_run_observation_key
                then epc.identity_observation_key
            else pp.identity_observation_key
        end,
        policy.policy_version,
        policy.rule_code,
        policy.rule_logic_version,
        policy.rule_priority,
        policy.evidence_class,
        policy.source_pair_scope
    from observations as pp
    inner join observations as epc
        on
            pp.postcode = epc.postcode
            and pp.premise_address_comparison = epc.premise_address_comparison
            and pp.source_dataset = 'PPD'
            and epc.source_dataset = 'EPC_CERTIFICATE'
    inner join enabled_policy as policy
        on policy.rule_code = 'P01_POSTCODE_PREMISE_EXACT'

    union all

    select
        pp.identity_run_id,
        pp.identity_run_key,
        least(pp.identity_run_observation_key, epc.identity_run_observation_key),
        greatest(pp.identity_run_observation_key, epc.identity_run_observation_key),
        case
            when pp.identity_run_observation_key < epc.identity_run_observation_key
                then pp.identity_observation_key
            else epc.identity_observation_key
        end,
        case
            when pp.identity_run_observation_key < epc.identity_run_observation_key
                then epc.identity_observation_key
            else pp.identity_observation_key
        end,
        policy.policy_version,
        policy.rule_code,
        policy.rule_logic_version,
        policy.rule_priority,
        policy.evidence_class,
        policy.source_pair_scope
    from observations as pp
    inner join observations as epc
        on
            pp.postcode_sector = epc.postcode_sector
            and pp.premise_address_comparison = epc.premise_address_comparison
            and pp.postcode <> epc.postcode
            and pp.source_dataset = 'PPD'
            and epc.source_dataset = 'EPC_CERTIFICATE'
    inner join enabled_policy as policy
        on policy.rule_code = 'P02_SECTOR_PREMISE_EXACT'
),

keyed as (
    select
        {{ stable_sha256(
            'epc-v4.identity.candidate-pair',
            'v1',
            ['identity_run_key', 'run_observation_key_l', 'run_observation_key_r']
        ) }} as candidate_pair_key,
        *
    from raw_rule_hits
),

rule_hits as (
    select
        {{ stable_sha256(
            'epc-v4.identity.candidate-rule-hit',
            'v1',
            ['candidate_pair_key', 'rule_code']
        ) }} as candidate_rule_hit_key,
        *,
        current_timestamp as generated_at
    from keyed
)

select *
from rule_hits
{% if is_incremental() %}
    where not exists (
        select 1
        from {{ this }} as existing_rule_hit
        where existing_rule_hit.candidate_rule_hit_key = rule_hits.candidate_rule_hit_key
    )
{% endif %}
