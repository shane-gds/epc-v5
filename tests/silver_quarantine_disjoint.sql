-- noqa: disable=AL03
select
    'PPD' as source_dataset,
    silver.source_record_key
from {{ ref('stg_pp_transaction_observation') }} as silver
inner join {{ ref('quarantine_source_record') }} as quarantine
    on
        silver.source_record_key = quarantine.source_record_key
        and quarantine.source_dataset = 'PPD'
        and quarantine.replay_status <> 'REPLAY_SUCCEEDED'

union all

select
    'EPC_CERTIFICATE',
    silver.source_record_key
from {{ ref('stg_epc_certificate_observation') }} as silver
inner join {{ ref('quarantine_source_record') }} as quarantine
    on
        silver.source_record_key = quarantine.source_record_key
        and quarantine.source_dataset = 'EPC_CERTIFICATE'
        and quarantine.replay_status <> 'REPLAY_SUCCEEDED'

union all

select
    'EPC_RECOMMENDATION',
    silver.source_record_key
from {{ ref('stg_epc_recommendation_observation') }} as silver
inner join {{ ref('quarantine_source_record') }} as quarantine
    on
        silver.source_record_key = quarantine.source_record_key
        and quarantine.source_dataset = 'EPC_RECOMMENDATION'
        and quarantine.replay_status <> 'REPLAY_SUCCEEDED'

union all

select
    'ONSUD',
    quarantine.source_record_key
from {{ ref('quarantine_source_record') }} as quarantine
inner join {{ source('bronze_ingestion', 'raw_onsud_uprn') }} as bronze
    on quarantine.source_record_key = bronze.source_record_key
where
    quarantine.source_dataset = 'ONSUD'
    and quarantine.replay_status <> 'REPLAY_SUCCEEDED'
    and {{ try_strict_unsigned_integer('bronze.uprn_raw', 'ubigint') }} > 0
