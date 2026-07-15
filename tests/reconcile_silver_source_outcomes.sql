-- noqa: disable=AL03
with raw_counts as (
    select
        'PPD' as source_dataset,
        count(*) as raw_count
    from {{ source('bronze_ingestion', 'raw_pp_transaction') }}
    union all
    select
        'EPC_CERTIFICATE',
        count(*)
    from {{ source('bronze_ingestion', 'raw_epc_certificate') }}
    union all
    select
        'EPC_RECOMMENDATION',
        count(*)
    from {{ source('bronze_ingestion', 'raw_epc_recommendation') }}
    union all
    select
        'ONSUD',
        count(*)
    from {{ source('bronze_ingestion', 'raw_onsud_uprn') }}
),

accepted_counts as (
    select
        'PPD' as source_dataset,
        count(*) as accepted_count
    from {{ ref('stg_pp_transaction_observation') }}
    union all
    select
        'EPC_CERTIFICATE',
        count(*)
    from {{ ref('stg_epc_certificate_observation') }}
    union all
    select
        'EPC_RECOMMENDATION',
        count(*)
    from {{ ref('stg_epc_recommendation_observation') }}
    union all
    select
        'ONSUD',
        coalesce(sum(source_record_count), 0)
    from {{ ref('stg_onsud_uprn_allocation') }}
),

quarantine_counts as (
    select
        source_dataset,
        count(distinct source_record_key) as quarantine_count
    from {{ ref('quarantine_source_record') }}
    where replay_status <> 'REPLAY_SUCCEEDED'
    group by source_dataset
)

select
    raw_source.source_dataset,
    raw_source.raw_count,
    accepted.accepted_count,
    coalesce(quarantine.quarantine_count, 0) as quarantine_count
from raw_counts as raw_source
inner join accepted_counts as accepted
    on raw_source.source_dataset = accepted.source_dataset
left join quarantine_counts as quarantine
    on raw_source.source_dataset = quarantine.source_dataset
where raw_source.raw_count <> accepted.accepted_count + coalesce(quarantine.quarantine_count, 0)
