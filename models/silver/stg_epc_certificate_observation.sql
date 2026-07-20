-- noqa: disable=RF02
{{ config(materialized='table', tags=['silver', 'epc']) }}

with source as (
    select
        *,
        nullif(trim(certificate_number_raw), '') as certificate_number_value,
        nullif(trim(inspection_date_raw), '') as inspection_date_text,
        try_strptime(trim(inspection_date_raw), '%Y-%m-%d') as inspection_timestamp_value,
        nullif(trim(lodgement_date_raw), '') as lodgement_date_text,
        try_strptime(trim(lodgement_date_raw), '%Y-%m-%d') as lodgement_timestamp_value,
        try_strptime(trim(lodgement_datetime_raw), '%Y-%m-%d %H:%M:%S') as lodgement_datetime_value,
        upper(nullif(trim(current_energy_rating_raw), '')) as current_rating_value,
        try_cast(trim(current_energy_efficiency_raw) as smallint) as current_efficiency_value,
        upper(nullif(trim(potential_energy_rating_raw), '')) as potential_rating_value,
        try_cast(trim(potential_energy_efficiency_raw) as smallint) as potential_efficiency_value,
        {{ try_strict_unsigned_integer('uprn_raw', 'ubigint') }} as uprn_value,
        try_cast(trim(total_floor_area_raw) as decimal(18, 2)) as total_floor_area_value,
        {{ stable_sha256(
            'epc-v5.silver.epc-certificate-payload',
            'v1',
            [
                'certificate_number_raw',
                'inspection_date_raw',
                'lodgement_date_raw',
                'lodgement_datetime_raw',
                'address1_raw',
                'address2_raw',
                'address3_raw',
                'address_raw',
                'posttown_raw',
                'postcode_raw',
                'uprn_raw',
                'current_energy_rating_raw',
                'current_energy_efficiency_raw',
                'potential_energy_rating_raw',
                'potential_energy_efficiency_raw',
                'tenure_raw',
                'property_type_raw',
                'built_form_raw',
                'construction_age_band_raw',
                'total_floor_area_raw',
                'main_fuel_raw',
                'walls_description_raw',
                'walls_energy_eff_raw',
                'floor_description_raw',
                'floor_energy_eff_raw',
                'roof_description_raw',
                'roof_energy_eff_raw',
                'windows_description_raw',
                'windows_energy_eff_raw',
                'mainheat_description_raw',
                'mainheat_energy_eff_raw',
                'hotwater_description_raw',
                'hot_water_energy_eff_raw'
            ]
        ) }} as payload_hash
    from {{ source('bronze_ingestion', 'raw_epc_certificate') }}
),

accepted as (
    select *
    from source
    where
        certificate_number_value is not null
        and inspection_date_text is not null
        and inspection_timestamp_value is not null
        and lodgement_date_text is not null
        and lodgement_timestamp_value is not null
        and current_rating_value in ('A', 'B', 'C', 'D', 'E', 'F', 'G')
        and current_efficiency_value > 0
),

natural_key_profile as (
    select
        certificate_number_value,
        count(*) as observation_count,
        count(distinct payload_hash) as distinct_payload_count
    from accepted
    group by certificate_number_value
),

classified as (
    select
        accepted.*,
        profile.observation_count,
        case
            when profile.observation_count = 1 then 'UNIQUE'
            when profile.distinct_payload_count = 1 then 'EXACT_DUPLICATE'
            else 'CONFLICT'
        end as certificate_conflict_status
    from accepted
    inner join natural_key_profile as profile
        on accepted.certificate_number_value = profile.certificate_number_value
)

select
    source_record_key,
    dataset_release_id,
    source_file_id,
    source_row_number,
    pipeline_run_id,
    loaded_at,
    certificate_number_value as certificate_number,
    cast(inspection_timestamp_value as date) as inspection_date,
    cast(lodgement_timestamp_value as date) as lodgement_date,
    lodgement_datetime_value as lodgement_datetime,
    nullif(trim(address1_raw), '') as address1,
    nullif(trim(address2_raw), '') as address2,
    nullif(trim(address3_raw), '') as address3,
    nullif(trim(address_raw), '') as address,
    nullif(trim(posttown_raw), '') as posttown,
    {{ normalise_address(
        "coalesce(nullif(trim(address_raw), ''), concat_ws(' ', nullif(trim(address1_raw), ''), nullif(trim(address2_raw), ''), nullif(trim(address3_raw), '')))"
    ) }} as address_comparison,
    'address_v1' as normaliser_version,
    {{ normalise_uk_postcode('postcode_raw') }} as postcode,
    {{ uk_postcode_parse_status('postcode_raw') }} as postcode_parse_status,
    case when uprn_value > 0 then uprn_value end as uprn,
    case
        when nullif(trim(uprn_raw), '') is null then 'MISSING'
        when uprn_value is null or uprn_value = 0 then 'INVALID'
        else 'VALID'
    end as uprn_parse_status,
    current_rating_value as current_energy_rating,
    current_efficiency_value as current_energy_efficiency,
    potential_rating_value as potential_energy_rating,
    potential_efficiency_value as potential_energy_efficiency,
    case
        when potential_efficiency_value is null then 'MISSING'
        when potential_efficiency_value <= 0 then 'INVALID'
        else 'VALID'
    end as potential_efficiency_parse_status,
    case
        when current_efficiency_value > 100 then 'ABOVE_STANDARD_RANGE'
        else 'STANDARD_RANGE'
    end as current_efficiency_range_status,
    case
        when current_rating_value = {{ epc_rating_for_score('current_efficiency_value') }}
            then 'CONSISTENT'
        else 'INCONSISTENT'
    end as current_band_score_status,
    case
        when cast(inspection_timestamp_value as date) > cast(lodgement_timestamp_value as date)
            then 'INSPECTION_AFTER_LODGEMENT'
        else 'VALID'
    end as chronology_status,
    nullif(trim(tenure_raw), '') as tenure_observation,
    case
        when nullif(trim(tenure_raw), '') is null then 'MISSING'
        when lower(trim(tenure_raw)) = 'unknown' then 'SOURCE_UNKNOWN'
        else 'OBSERVED'
    end as tenure_observation_status,
    nullif(trim(property_type_raw), '') as property_type,
    nullif(trim(built_form_raw), '') as built_form,
    nullif(trim(construction_age_band_raw), '') as construction_age_band,
    total_floor_area_value as total_floor_area,
    case
        when nullif(trim(total_floor_area_raw), '') is null then 'MISSING'
        when total_floor_area_value is null or total_floor_area_value <= 0 then 'INVALID'
        else 'VALID'
    end as total_floor_area_parse_status,
    nullif(trim(main_fuel_raw), '') as main_fuel,
    nullif(trim(walls_description_raw), '') as walls_description,
    nullif(trim(walls_energy_eff_raw), '') as walls_energy_eff,
    nullif(trim(floor_description_raw), '') as floor_description,
    nullif(trim(floor_energy_eff_raw), '') as floor_energy_eff,
    nullif(trim(roof_description_raw), '') as roof_description,
    nullif(trim(roof_energy_eff_raw), '') as roof_energy_eff,
    nullif(trim(windows_description_raw), '') as windows_description,
    nullif(trim(windows_energy_eff_raw), '') as windows_energy_eff,
    nullif(trim(mainheat_description_raw), '') as mainheat_description,
    nullif(trim(mainheat_energy_eff_raw), '') as mainheat_energy_eff,
    nullif(trim(hotwater_description_raw), '') as hotwater_description,
    nullif(trim(hot_water_energy_eff_raw), '') as hot_water_energy_eff,
    certificate_conflict_status,
    observation_count as certificate_observation_count,
    'VALID' as parse_status
from classified
