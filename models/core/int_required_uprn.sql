{{ config(materialized='table', tags=['core', 'intermediate', 'location']) }}

with selected_onsud_release as (
    select
        dataset_release_id,
        release_key,
        release_label
    from {{ source('audit_ingestion', 'audit_dataset_release') }}
    where
        dataset_code = 'ONSUD'
        and release_label = '{{ var("onsud_release_label") }}'
        and status = 'LOADED'
),

required_from_epc as (
    select
        uprn,
        count(*) as source_reference_count,
        count(distinct certificate_number) as distinct_certificate_count,
        min(inspection_date) as first_observed_date,
        max(inspection_date) as last_observed_date
    from {{ ref('stg_epc_certificate_observation') }}
    where uprn_parse_status = 'VALID'
    group by uprn
)

select
    {{ stable_sha256(
        'epc-v5.location.required-uprn',
        'v1',
        [
            'onsud_release.release_key',
            'cast(required_epc.uprn as varchar)',
            "'EPC_SILVER_V1'"
        ]
    ) }} as required_uprn_key,
    onsud_release.dataset_release_id as onsud_dataset_release_id,
    onsud_release.release_key as onsud_release_key,
    onsud_release.release_label as onsud_release_label,
    required_epc.uprn,
    'EPC_CERTIFICATE' as requirement_reason,
    'EPC_SILVER_V1' as requirement_scope,
    required_epc.source_reference_count,
    required_epc.distinct_certificate_count,
    required_epc.first_observed_date,
    required_epc.last_observed_date
from required_from_epc as required_epc
cross join selected_onsud_release as onsud_release
