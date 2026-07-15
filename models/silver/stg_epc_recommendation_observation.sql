{{ config(materialized='table', tags=['silver', 'epc', 'recommendation']) }}

with parent_profile as (
    select
        certificate_number,
        count(*) as parent_observation_count,
        count(*) filter (where certificate_conflict_status = 'CONFLICT')
            as conflicting_parent_count
    from {{ ref('stg_epc_certificate_observation') }}
    group by certificate_number
),

source as (
    select
        *,
        nullif(trim(certificate_number_raw), '') as certificate_number_value,
        {{ try_strict_unsigned_integer('improvement_item_raw', 'integer') }}
            as improvement_item_value,
        {{ normalise_gbp_cost_text('indicative_cost_raw') }} as cost_text
    from {{ source('bronze_ingestion', 'raw_epc_recommendation') }}
),

accepted as (
    select *
    from source
    where
        certificate_number_value is not null
        and improvement_item_value > 0
),

cost_shape as (
    select
        *,
        case
            when cost_text is null then 'MISSING'
            when position('Â£' in cost_text) > 0 then 'ENCODING_ERROR'
            when
                position('$' in cost_text) > 0
                or position('€' in cost_text) > 0
                or position('₹' in cost_text) > 0
                or position('¥' in cost_text) > 0 then 'NON_GBP_CURRENCY'
            when regexp_full_match(
                upper(cost_text),
                '^(£|GBP\s*)[0-9][0-9,]*(\.[0-9]{1,2})?\s*-\s*'
                || '(£|GBP\s*)[0-9][0-9,]*(\.[0-9]{1,2})?$'
            ) then 'RANGE_CANDIDATE'
            when regexp_full_match(
                upper(cost_text),
                '^(£|GBP\s*)[0-9][0-9,]*(\.[0-9]{1,2})?$'
            ) then 'SINGLE_CANDIDATE'
            when regexp_full_match(cost_text, '^[0-9][0-9,]*(\.[0-9]{1,2})?$')
                then 'BARE_NUMBER_UNSUPPORTED'
            else 'UNSUPPORTED_FORMAT'
        end as cost_shape,
        {{ gbp_cost_numeric_text('indicative_cost_raw') }} as numeric_cost_text
    from accepted
),

cost_values as (
    select
        *,
        case
            when cost_shape = 'RANGE_CANDIDATE'
                then try_cast(split_part(numeric_cost_text, '-', 1) as decimal(18, 2))
            when cost_shape = 'SINGLE_CANDIDATE'
                then try_cast(numeric_cost_text as decimal(18, 2))
        end as cost_low_value,
        case
            when cost_shape = 'RANGE_CANDIDATE'
                then try_cast(split_part(numeric_cost_text, '-', 2) as decimal(18, 2))
            when cost_shape = 'SINGLE_CANDIDATE'
                then try_cast(numeric_cost_text as decimal(18, 2))
        end as cost_high_value
    from cost_shape
)

select
    recommendation.source_record_key,
    recommendation.dataset_release_id,
    recommendation.source_file_id,
    recommendation.source_row_number,
    recommendation.pipeline_run_id,
    recommendation.loaded_at,
    recommendation.certificate_number_value as certificate_number,
    recommendation.improvement_item_value as improvement_item,
    recommendation.cost_text as indicative_cost_observation,
    'VALID' as parse_status,
    nullif(trim(recommendation.improvement_id_raw), '') as improvement_id,
    nullif(trim(recommendation.improvement_summary_text_raw), '') as improvement_summary_text,
    nullif(trim(recommendation.improvement_descr_text_raw), '') as improvement_description_text,
    coalesce(
        nullif(trim(recommendation.improvement_descr_text_raw), ''),
        nullif(trim(recommendation.improvement_summary_text_raw), '')
    ) as recommendation_text,
    case
        when
            nullif(trim(recommendation.improvement_summary_text_raw), '') is null
            and nullif(trim(recommendation.improvement_descr_text_raw), '') is null then 'MISSING'
        else 'OBSERVED'
    end as recommendation_text_status,
    case
        when
            recommendation.cost_shape = 'RANGE_CANDIDATE'
            and (recommendation.cost_low_value is null or recommendation.cost_high_value is null)
            then 'NUMERIC_OVERFLOW'
        when
            recommendation.cost_shape = 'RANGE_CANDIDATE'
            and recommendation.cost_low_value > recommendation.cost_high_value then 'INVALID_BOUNDS'
        when recommendation.cost_shape = 'RANGE_CANDIDATE' then 'RANGE_PARSED'
        when
            recommendation.cost_shape = 'SINGLE_CANDIDATE'
            and recommendation.cost_low_value is null then 'NUMERIC_OVERFLOW'
        when recommendation.cost_shape = 'SINGLE_CANDIDATE' then 'SINGLE_VALUE_PARSED'
        else recommendation.cost_shape
    end as cost_parse_status,
    case
        when
            recommendation.cost_shape = 'RANGE_CANDIDATE'
            and recommendation.cost_low_value is not null
            and recommendation.cost_high_value is not null
            and recommendation.cost_low_value <= recommendation.cost_high_value
            then recommendation.cost_low_value
        when
            recommendation.cost_shape = 'SINGLE_CANDIDATE'
            and recommendation.cost_low_value is not null
            then recommendation.cost_low_value
    end as indicative_cost_low_gbp,
    case
        when
            recommendation.cost_shape = 'RANGE_CANDIDATE'
            and recommendation.cost_low_value is not null
            and recommendation.cost_high_value is not null
            and recommendation.cost_low_value <= recommendation.cost_high_value
            then recommendation.cost_high_value
        when
            recommendation.cost_shape = 'SINGLE_CANDIDATE'
            and recommendation.cost_high_value is not null
            then recommendation.cost_high_value
    end as indicative_cost_high_gbp,
    case
        when parent.parent_observation_count is null then 'ORPHAN_CERTIFICATE'
        when parent.conflicting_parent_count > 0 then 'CONFLICTING_CERTIFICATE'
        else 'MATCHED_CERTIFICATE'
    end as parent_status,
    coalesce(parent.parent_observation_count, 0) as parent_observation_count
from cost_values as recommendation
left join parent_profile as parent
    on recommendation.certificate_number_value = parent.certificate_number
