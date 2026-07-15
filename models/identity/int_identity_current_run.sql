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
                'population_fingerprint',
                "'identity_input_v1'",
                "'address_v1'",
                "'identity_eligibility_v1'"
            ]
        ) }} as identity_run_key,
        population_fingerprint,
        input_source_file_count,
        input_release_keys
    from population
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
    'identity_input_v1' as algorithm_version,
    'address_v1' as normaliser_version,
    'identity_eligibility_v1' as eligibility_contract_version,
    current_timestamp as calculated_at
from keyed
