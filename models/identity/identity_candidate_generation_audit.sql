{{ config(materialized='table', tags=['identity', 'candidate_generation', 'audit']) }}

with current_run as (
    select
        identity_run_id,
        identity_run_key
    from {{ ref('int_identity_current_run') }}
),

rule_metrics as (
    select
        rule_hit.identity_run_id,
        rule_hit.identity_run_key,
        rule_hit.policy_version,
        rule_hit.rule_code,
        rule_hit.rule_logic_version,
        count(*) as rule_hit_count,
        count(distinct rule_hit.run_observation_key_l) as distinct_left_endpoints,
        count(distinct rule_hit.run_observation_key_r) as distinct_right_endpoints,
        min(rule_hit.candidate_rule_hit_key) as minimum_rule_hit_key,
        max(rule_hit.candidate_rule_hit_key) as maximum_rule_hit_key,
        bit_xor(hash(rule_hit.candidate_rule_hit_key)) as operational_rule_hit_checksum
    from {{ ref('identity_candidate_rule_hit') }} as rule_hit
    inner join current_run
        on rule_hit.identity_run_key = current_run.identity_run_key
    group by
        rule_hit.identity_run_id, rule_hit.identity_run_key,
        rule_hit.policy_version, rule_hit.rule_code, rule_hit.rule_logic_version
),

pair_metrics as (
    select
        pair.identity_run_key,
        count(*) as candidate_pair_count,
        count(distinct pair.run_observation_key_l) as pair_left_endpoints,
        count(distinct pair.run_observation_key_r) as pair_right_endpoints,
        min(pair.candidate_pair_key) as minimum_pair_key,
        max(pair.candidate_pair_key) as maximum_pair_key,
        bit_xor(hash(pair.candidate_pair_key)) as operational_pair_checksum
    from {{ ref('identity_candidate_pair') }} as pair
    inner join current_run
        on pair.identity_run_key = current_run.identity_run_key
    group by pair.identity_run_key
)

select
    rule_metrics.*,
    pair_metrics.candidate_pair_count,
    pair_metrics.pair_left_endpoints,
    pair_metrics.pair_right_endpoints,
    pair_metrics.minimum_pair_key,
    pair_metrics.maximum_pair_key,
    pair_metrics.operational_pair_checksum,
    current_timestamp as audited_at
from rule_metrics
inner join pair_metrics on rule_metrics.identity_run_key = pair_metrics.identity_run_key
