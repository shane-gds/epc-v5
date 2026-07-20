{{ config(materialized='table', tags=['identity', 'candidate_generation']) }}

with current_run as (
    select
        identity_run_id,
        identity_run_key,
        blocking_policy_version
    from {{ ref('int_identity_current_run') }}
),

policy as (
    select
        blocking_policy.maximum_side_count,
        blocking_policy.maximum_pair_product
    from {{ ref('identity_blocking_policy') }} as blocking_policy
    inner join current_run
        on blocking_policy.policy_version = current_run.blocking_policy_version
    where
        blocking_policy.rule_code = 'P04_LIBPOSTAL_UNIT_BUILDING_ROAD'
        and blocking_policy.enabled
),

component_observations as (
    select observation.*
    from {{ ref('int_identity_observation') }} as observation
    inner join current_run
        on observation.identity_run_key = current_run.identity_run_key
    where
        observation.is_identity_eligible
        and observation.address_component_status = 'COMPLETE'
        and observation.unit_identifier_comparison is not null
        and observation.building_number_designator is not null
        and observation.road_comparison is not null
),

profiled as (
    select
        observation.identity_run_id,
        observation.identity_run_key,
        observation.postcode,
        observation.unit_identifier_comparison,
        observation.building_number_designator,
        count(*) filter (where observation.source_dataset = 'PPD') as ppd_side_count,
        count(*) filter (
            where
            observation.source_dataset = 'EPC_CERTIFICATE'
            and observation.address_component_method = 'LIBPOSTAL'
        ) as epc_side_count
    from component_observations as observation
    group by
        observation.identity_run_id,
        observation.identity_run_key,
        observation.postcode,
        observation.unit_identifier_comparison,
        observation.building_number_designator
    having
        count(*) filter (where observation.source_dataset = 'PPD') > 0
        and count(*) filter (
            where
            observation.source_dataset = 'EPC_CERTIFICATE'
            and observation.address_component_method = 'LIBPOSTAL'
        ) > 0
),

classified as (
    select
        profiled.*,
        policy.maximum_side_count,
        policy.maximum_pair_product,
        cast(profiled.ppd_side_count as uhugeint)
        * cast(profiled.epc_side_count as uhugeint) as candidate_pair_product,
        case
            when
                profiled.ppd_side_count > policy.maximum_side_count
                or profiled.epc_side_count > policy.maximum_side_count
                then 'SUPPRESSED_OVERSIZED_SIDE'
            when
                cast(profiled.ppd_side_count as uhugeint)
                * cast(profiled.epc_side_count as uhugeint)
                > policy.maximum_pair_product
                then 'SUPPRESSED_OVERSIZED_PRODUCT'
            else 'ADMITTED'
        end as block_status
    from profiled
    cross join policy
)

select
    {{ stable_sha256(
        'epc-v5.identity.libpostal-candidate-block',
        'v1',
        [
            'identity_run_key',
            'postcode',
            'unit_identifier_comparison',
            'building_number_designator'
        ]
    ) }} as candidate_block_key,
    *,
    block_status = 'ADMITTED' as is_admitted
from classified
