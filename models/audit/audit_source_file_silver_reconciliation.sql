-- noqa: disable=AL03
{{ config(materialized='table', tags=['audit', 'silver_gate']) }}

with raw_counts as (
    select
        'PPD' as source_dataset,
        source_file_id,
        dataset_release_id,
        count(*) as raw_row_count
    from {{ source('bronze_ingestion', 'raw_pp_transaction') }}
    group by source_file_id, dataset_release_id
    union all
    select
        'EPC_CERTIFICATE',
        source_file_id,
        dataset_release_id,
        count(*)
    from {{ source('bronze_ingestion', 'raw_epc_certificate') }}
    group by source_file_id, dataset_release_id
    union all
    select
        'EPC_RECOMMENDATION',
        source_file_id,
        dataset_release_id,
        count(*)
    from {{ source('bronze_ingestion', 'raw_epc_recommendation') }}
    group by source_file_id, dataset_release_id
    union all
    select
        'ONSUD',
        source_file_id,
        dataset_release_id,
        count(*)
    from {{ source('bronze_ingestion', 'raw_onsud_uprn') }}
    group by source_file_id, dataset_release_id
),

accepted_counts as (
    select
        'PPD' as source_dataset,
        source_file_id,
        count(*) as silver_accepted_row_count
    from {{ ref('stg_pp_transaction_observation') }}
    group by source_file_id
    union all
    select
        'EPC_CERTIFICATE',
        source_file_id,
        count(*)
    from {{ ref('stg_epc_certificate_observation') }}
    group by source_file_id
    union all
    select
        'EPC_RECOMMENDATION',
        source_file_id,
        count(*)
    from {{ ref('stg_epc_recommendation_observation') }}
    group by source_file_id
    union all
    select
        'ONSUD',
        source_file_id,
        count(*)
    from {{ ref('bridge_onsud_allocation_source_record') }}
    group by source_file_id
),

quarantine_counts as (
    select
        source_dataset,
        source_file_id,
        count(distinct source_record_key) as silver_quarantined_row_count
    from {{ ref('quarantine_source_record') }}
    where replay_status <> 'REPLAY_SUCCEEDED'
    group by source_dataset, source_file_id
),

loaded_manifest as (
    select
        *,
        case
            when parser_contract_version like 'pp_%' then 'PPD'
            when parser_contract_version like 'domestic_epc_certificate_%'
                then 'EPC_CERTIFICATE'
            when parser_contract_version like 'domestic_epc_recommendation_%'
                then 'EPC_RECOMMENDATION'
            when parser_contract_version like 'onsud_%' then 'ONSUD'
        end as source_dataset
    from {{ source('audit_ingestion', 'audit_source_file') }}
    where
        file_kind in ('CSV', 'ZIP_MEMBER_CSV')
        and ingestion_status = 'LOADED'
),

reconciliation_base as (
    select
        manifest.dataset_release_id as manifest_dataset_release_id,
        raw_counts.dataset_release_id as raw_dataset_release_id,
        manifest.file_name,
        manifest.parser_contract_version,
        manifest.observed_row_count as audit_observed_row_count,
        coalesce(manifest.source_file_id, raw_counts.source_file_id) as source_file_id,
        coalesce(manifest.source_dataset, raw_counts.source_dataset) as source_dataset,
        coalesce(raw_counts.raw_row_count, 0) as raw_row_count,
        manifest.source_file_id is not null as has_loaded_manifest,
        raw_counts.source_file_id is not null as has_raw_relation
    from loaded_manifest as manifest
    full outer join raw_counts
        on manifest.source_file_id = raw_counts.source_file_id
)

select
    reconciliation.source_file_id,
    reconciliation.manifest_dataset_release_id as dataset_release_id,
    reconciliation.raw_dataset_release_id,
    reconciliation.source_dataset,
    reconciliation.file_name,
    reconciliation.parser_contract_version,
    reconciliation.audit_observed_row_count,
    reconciliation.raw_row_count,
    coalesce(accepted_counts.silver_accepted_row_count, 0) as silver_accepted_row_count,
    coalesce(quarantine_counts.silver_quarantined_row_count, 0)
        as silver_quarantined_row_count,
    case
        when
            reconciliation.has_loaded_manifest
            and (
                not reconciliation.has_raw_relation
                or reconciliation.manifest_dataset_release_id
                is not distinct from reconciliation.raw_dataset_release_id
            )
            and reconciliation.audit_observed_row_count = reconciliation.raw_row_count
            and reconciliation.raw_row_count
            = coalesce(accepted_counts.silver_accepted_row_count, 0)
            + coalesce(quarantine_counts.silver_quarantined_row_count, 0)
            then 'PASSED'
        else 'FAILED'
    end as reconciliation_status,
    current_timestamp as reconciled_at
from reconciliation_base as reconciliation
left join accepted_counts
    on
        reconciliation.source_dataset = accepted_counts.source_dataset
        and reconciliation.source_file_id = accepted_counts.source_file_id
left join quarantine_counts
    on
        reconciliation.source_dataset = quarantine_counts.source_dataset
        and reconciliation.source_file_id = quarantine_counts.source_file_id
