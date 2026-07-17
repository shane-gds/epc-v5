with p04_pairs as (
    select
        rule_hit.candidate_pair_key,
        left_observation.source_dataset as source_dataset_l,
        right_observation.source_dataset as source_dataset_r,
        left_observation.postcode as postcode_l,
        right_observation.postcode as postcode_r,
        left_observation.unit_identifier_comparison as unit_l,
        right_observation.unit_identifier_comparison as unit_r,
        left_observation.building_number_designator as building_l,
        right_observation.building_number_designator as building_r,
        left_observation.road_comparison as road_l,
        right_observation.road_comparison as road_r,
        left_observation.premise_address_comparison as premise_l,
        right_observation.premise_address_comparison as premise_r,
        left_observation.address_component_method as method_l,
        right_observation.address_component_method as method_r
    from {{ ref('identity_candidate_rule_hit') }} as rule_hit
    inner join {{ ref('int_identity_observation') }} as left_observation
        on rule_hit.run_observation_key_l = left_observation.identity_run_observation_key
    inner join {{ ref('int_identity_observation') }} as right_observation
        on rule_hit.run_observation_key_r = right_observation.identity_run_observation_key
    inner join {{ ref('int_identity_current_run') }} as current_run
        on rule_hit.identity_run_key = current_run.identity_run_key
    where rule_hit.rule_code = 'P04_LIBPOSTAL_UNIT_BUILDING_ROAD'
)

select candidate_pair_key
from p04_pairs
where not (
    postcode_l = postcode_r
    and unit_l = unit_r
    and building_l = building_r
    and premise_l <> premise_r
    and (
        (
            source_dataset_l = 'PPD'
            and method_l = 'PPD_STRUCTURED_FIELDS'
            and source_dataset_r = 'EPC_CERTIFICATE'
            and method_r = 'LIBPOSTAL'
            and contains(concat(' ', road_r, ' '), concat(' ', road_l, ' '))
        )
        or (
            source_dataset_r = 'PPD'
            and method_r = 'PPD_STRUCTURED_FIELDS'
            and source_dataset_l = 'EPC_CERTIFICATE'
            and method_l = 'LIBPOSTAL'
            and contains(concat(' ', road_l, ' '), concat(' ', road_r, ' '))
        )
    )
)
