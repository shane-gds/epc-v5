{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='epc_certificate_key',
    on_schema_change='append_new_columns',
    tags=['core', 'fact', 'epc']
) }}

with staged as (
    select
        certificate.*,
        dataset_release.release_key
    from {{ ref('stg_epc_certificate_observation') }} as certificate
    inner join {{ source('audit_ingestion', 'audit_dataset_release') }} as dataset_release
        on certificate.dataset_release_id = dataset_release.dataset_release_id
),

duplicate_representative as (
    select
        release_key,
        certificate_number,
        min(source_record_key) as representative_source_record_key
    from staged
    where certificate_observation_count > 1
    group by release_key, certificate_number
),

canonical as (
    select staged.*
    from staged
    left join duplicate_representative as duplicate
        on
            staged.release_key = duplicate.release_key
            and staged.certificate_number = duplicate.certificate_number
    where
        staged.certificate_observation_count = 1
        or staged.source_record_key = duplicate.representative_source_record_key
),

facts as (
    select
        {{ stable_sha256(
            'uk.gov.epc.domestic-certificate',
            'v1',
            ['release_key', 'certificate_number']
        ) }} as epc_certificate_key,
        certificate_number,
        inspection_date,
        lodgement_date,
        lodgement_datetime,
        address1,
        address2,
        address3,
        address,
        posttown,
        postcode,
        postcode_parse_status,
        uprn as uprn_observation,
        uprn_parse_status,
        current_energy_rating,
        current_energy_efficiency,
        potential_energy_rating,
        potential_energy_efficiency,
        potential_efficiency_parse_status,
        current_efficiency_range_status,
        current_band_score_status,
        chronology_status,
        tenure_observation,
        tenure_observation_status,
        property_type,
        built_form,
        construction_age_band,
        total_floor_area,
        total_floor_area_parse_status,
        main_fuel,
        walls_description,
        walls_energy_eff,
        floor_description,
        floor_energy_eff,
        roof_description,
        roof_energy_eff,
        windows_description,
        windows_energy_eff,
        mainheat_description,
        mainheat_energy_eff,
        hotwater_description,
        hot_water_energy_eff,
        certificate_conflict_status,
        certificate_observation_count,
        'OBSERVED' as certificate_record_status,
        source_record_key,
        dataset_release_id,
        release_key,
        source_file_id,
        source_row_number,
        pipeline_run_id,
        loaded_at,
        'epc_certificate_v1' as fact_contract_version
    from canonical
)

select *
from facts
{% if is_incremental() %}
    where not exists (
        select 1
        from {{ this }} as existing_fact
        where existing_fact.epc_certificate_key = facts.epc_certificate_key
    )
{% endif %}
