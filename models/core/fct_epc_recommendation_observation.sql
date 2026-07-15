{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='epc_recommendation_key',
    on_schema_change='append_new_columns',
    tags=['core', 'fact', 'recommendation']
) }}

with staged as (
    select
        recommendation.*,
        dataset_release.release_key
    from {{ ref('stg_epc_recommendation_observation') }} as recommendation
    inner join {{ source('audit_ingestion', 'audit_dataset_release') }} as dataset_release
        on recommendation.dataset_release_id = dataset_release.dataset_release_id
),

facts as (
    select
        {{ stable_sha256(
            'uk.gov.epc.domestic-recommendation-observation',
            'v1',
            [
                'recommendation.release_key',
                'recommendation.certificate_number',
                'cast(recommendation.improvement_item as varchar)',
                'recommendation.improvement_id',
                'recommendation.source_record_key'
            ]
        ) }} as epc_recommendation_key,
        certificate.epc_certificate_key,
        recommendation.certificate_number,
        recommendation.improvement_item,
        recommendation.improvement_id,
        recommendation.improvement_summary_text,
        recommendation.improvement_description_text,
        recommendation.recommendation_text,
        recommendation.recommendation_text_status,
        recommendation.indicative_cost_observation,
        recommendation.cost_parse_status,
        recommendation.indicative_cost_low_gbp,
        recommendation.indicative_cost_high_gbp,
        recommendation.parent_status,
        recommendation.parent_observation_count,
        'OBSERVED' as recommendation_record_status,
        recommendation.source_record_key,
        recommendation.dataset_release_id,
        recommendation.release_key,
        recommendation.source_file_id,
        recommendation.source_row_number,
        recommendation.pipeline_run_id,
        recommendation.loaded_at,
        'epc_recommendation_observation_v1' as fact_contract_version
    from staged as recommendation
    left join {{ ref('fct_epc_certificate') }} as certificate
        on
            recommendation.dataset_release_id = certificate.dataset_release_id
            and recommendation.certificate_number = certificate.certificate_number
)

select *
from facts
{% if is_incremental() %}
    where not exists (
        select 1
        from {{ this }} as existing_fact
        where existing_fact.epc_recommendation_key = facts.epc_recommendation_key
    )
{% endif %}
