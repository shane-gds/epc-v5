{{ config(materialized='table', tags=['identity', 'intermediate']) }}

with identity_inputs as (
    select
        dataset_release.dataset_code,
        dataset_release.release_key,
        source_file.file_name,
        source_file.content_sha256
    from {{ source('audit_ingestion', 'audit_source_file') }} as source_file
    inner join {{ source('audit_ingestion', 'audit_dataset_release') }} as dataset_release
        on source_file.dataset_release_id = dataset_release.dataset_release_id
    where
        dataset_release.dataset_code in ('PPD', 'EPC_DOMESTIC_BULK')
        and source_file.parent_source_file_id is null
        and source_file.ingestion_status = 'LOADED'
),

blocking_policy as (
    select
        sha256(
            string_agg(
                concat_ws(
                    ':',
                    policy_version,
                    rule_code,
                    rule_logic_version,
                    cast(rule_priority as varchar),
                    evidence_class,
                    cast(enabled as varchar),
                    source_pair_scope,
                    coalesce(cast(maximum_side_count as varchar), 'NULL'),
                    coalesce(cast(maximum_pair_product as varchar), 'NULL'),
                    oversized_action
                ),
                '|' order by rule_priority, rule_code
            )
        ) as blocking_policy_fingerprint,
        count(*) as blocking_rule_count
    from {{ ref('identity_blocking_policy') }}
    where policy_version = '{{ var("identity_blocking_policy_version") }}'
),

population as (
    select
        sha256(
            string_agg(
                concat(dataset_code, ':', release_key, ':', file_name, ':', content_sha256),
                '|' order by dataset_code, file_name
            )
        ) as population_fingerprint,
        count(*) as input_source_file_count,
        string_agg(distinct release_key, '|' order by release_key) as input_release_keys
    from identity_inputs
),

keyed as (
    select
        {{ stable_sha256(
            'epc-v4.identity.run',
            'v1',
            [
                'population.population_fingerprint',
                'blocking_policy.blocking_policy_fingerprint',
                "'" ~ var('identity_input_algorithm_version') ~ "'",
                "'" ~ var('identity_address_normaliser_version') ~ "'",
                "'" ~ var('identity_eligibility_contract_version') ~ "'",
                "'" ~ var('identity_comparison_model_version') ~ "'",
                "'" ~ var('identity_decision_policy_version') ~ "'"
            ]
        ) }} as identity_run_key,
        population.population_fingerprint,
        population.input_source_file_count,
        population.input_release_keys,
        blocking_policy.blocking_policy_fingerprint,
        blocking_policy.blocking_rule_count
    from population
    cross join blocking_policy
)

select
    cast(
        concat(
            substr(identity_run_key, 1, 8), '-',
            substr(identity_run_key, 9, 4), '-',
            substr(identity_run_key, 13, 4), '-',
            substr(identity_run_key, 17, 4), '-',
            substr(identity_run_key, 21, 12)
        ) as uuid
    ) as identity_run_id,
    identity_run_key,
    population_fingerprint,
    input_source_file_count,
    input_release_keys,
    blocking_policy_fingerprint,
    blocking_rule_count,
    '{{ var("identity_input_algorithm_version") }}' as algorithm_version,
    '{{ var("identity_address_normaliser_version") }}' as normaliser_version,
    '{{ var("identity_eligibility_contract_version") }}' as eligibility_contract_version,
    '{{ var("identity_blocking_policy_version") }}' as blocking_policy_version,
    '{{ var("identity_comparison_model_version") }}' as comparison_model_version,
    '{{ var("identity_decision_policy_version") }}' as decision_policy_version,
    current_timestamp as calculated_at
from keyed
