{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='assignment_key',
    on_schema_change='append_new_columns',
    pre_hook="{{ assert_identity_assignment_prepublication_completeness() }}",
    tags=['identity', 'decision', 'assignment']
) }}

{% if flags.FULL_REFRESH %}
    {{ exceptions.raise_compiler_error(
        'Full refresh is prohibited for the governed source-record assignment ledger'
    ) }}
{% endif %}

with selected_run as (
    select
        current_identity_run.identity_run_id,
        current_identity_run.identity_run_key,
        run_manifest.registered_at,
        current_identity_run.decision_policy_version
    from {{ ref('int_identity_current_run') }} as current_identity_run
    inner join {{ ref('identity_run_manifest') }} as run_manifest
        on current_identity_run.identity_run_key = run_manifest.identity_run_key
),

{% if is_incremental() %}
    assignment_profile as (
        select
            count(*) as assignment_count,
            count(*) filter (where assignment_row.is_current) as current_assignment_count
        from {{ this }} as assignment_row
        inner join selected_run
            on assignment_row.identity_run_key = selected_run.identity_run_key
    ),

{% endif %}

eligible_profile as (
    select count(*) as eligible_count
    from {{ ref('int_identity_observation') }} as observation
    inner join selected_run
        on observation.identity_run_key = selected_run.identity_run_key
    where observation.is_identity_eligible
),

current_run as (
    select selected_run.*
    from selected_run
    {% if is_incremental() %}
        cross join assignment_profile
        cross join eligible_profile
        where case {{ identity_assignment_publication_action(
            'assignment_profile.assignment_count',
            'assignment_profile.current_assignment_count',
            'eligible_profile.eligible_count'
        ) }}
            when 'REACTIVATION_BLOCKED'
                then error(
                    'Historical identity-run reactivation requires a new execution manifest'
                )
            when 'INCOMPLETE_BLOCKED'
                then error('Existing assignment publication is incomplete or inconsistent')
            when 'PUBLISH' then true
            else false
        end
    {% endif %}
),

current_assignments as (
    select
        {{ stable_sha256(
            'epc-v4.identity.source-record-assignment',
            'v1',
            [
                'observation.identity_run_key',
                'observation.source_record_key',
                'hypothesis.identity_hypothesis_key',
                "'UNRESOLVED'",
                "case hypothesis.hypothesis_outcome when 'SINGLETON_NO_CANDIDATE' then 'NO_CANDIDATE_SINGLETON' else 'UNCALIBRATED_REVIEW_REQUIRED' end"
            ]
        ) }} as assignment_key,
        observation.source_record_key,
        observation.source_dataset,
        observation.identity_run_id as identity_resolution_run_id,
        observation.identity_run_key,
        observation.identity_run_observation_key,
        observation.identity_observation_key,
        hypothesis.identity_hypothesis_key as entity_hypothesis_key,
        hypothesis.identity_cluster_key,
        cast(null as uuid) as registry_entity_id,
        'UNRESOLVED' as assignment_status,
        case hypothesis.hypothesis_outcome
            when 'SINGLETON_NO_CANDIDATE' then 'NO_CANDIDATE_SINGLETON'
            else 'UNCALIBRATED_REVIEW_REQUIRED'
        end as assignment_method,
        cast(null as double) as assignment_confidence,
        'NOT_AVAILABLE_UNCALIBRATED' as assignment_confidence_basis,
        case hypothesis.hypothesis_outcome
            when 'SINGLETON_NO_CANDIDATE'
                then [
                    'NO_CANDIDATE',
                    'UNCALIBRATED_POLICY',
                    'REGISTRY_NOT_PROMOTED'
                ]
            else [
                'CANDIDATE_REVIEW_REQUIRED',
                'UNCALIBRATED_POLICY',
                'REGISTRY_NOT_PROMOTED'
            ]
        end as reason_codes,
        hypothesis.hypothesis_outcome,
        hypothesis.candidate_count,
        hypothesis.review_candidate_count,
        hypothesis.top_candidate_pair_key,
        hypothesis.top_match_weight,
        hypothesis.registry_promotion_status,
        current_run.decision_policy_version,
        current_run.registered_at as valid_from,
        cast(null as timestamptz) as valid_to,
        true as is_current,
        current_timestamp as assigned_at,
        'source_record_entity_assignment_v1' as assignment_contract_version
    from {{ ref('identity_hypothesis') }} as hypothesis
    inner join {{ ref('int_identity_observation') }} as observation
        on
            hypothesis.identity_run_key = observation.identity_run_key
            and hypothesis.identity_run_observation_key
            = observation.identity_run_observation_key
    inner join current_run
        on hypothesis.identity_run_key = current_run.identity_run_key
    where observation.is_identity_eligible
),

assignments_to_publish as (
    select *
    from current_assignments
    {% if is_incremental() %}
        where
            not exists (
                select 1
                from {{ this }} as existing_assignment
                where
                    existing_assignment.assignment_key
                    = current_assignments.assignment_key
            )

        union all by name

        select
            existing_assignment.assignment_key,
            existing_assignment.source_record_key,
            existing_assignment.source_dataset,
            existing_assignment.identity_resolution_run_id,
            existing_assignment.identity_run_key,
            existing_assignment.identity_run_observation_key,
            existing_assignment.identity_observation_key,
            existing_assignment.entity_hypothesis_key,
            existing_assignment.identity_cluster_key,
            existing_assignment.registry_entity_id,
            existing_assignment.assignment_status,
            existing_assignment.assignment_method,
            existing_assignment.assignment_confidence,
            existing_assignment.assignment_confidence_basis,
            existing_assignment.reason_codes,
            existing_assignment.hypothesis_outcome,
            existing_assignment.candidate_count,
            existing_assignment.review_candidate_count,
            existing_assignment.top_candidate_pair_key,
            existing_assignment.top_match_weight,
            existing_assignment.registry_promotion_status,
            existing_assignment.decision_policy_version,
            existing_assignment.valid_from,
            current_run.registered_at as valid_to,
            false as is_current,
            existing_assignment.assigned_at,
            existing_assignment.assignment_contract_version
        from {{ this }} as existing_assignment
        cross join current_run
        where
            existing_assignment.is_current
            and existing_assignment.identity_run_key <> current_run.identity_run_key
    {% endif %}
)

select *
from assignments_to_publish
