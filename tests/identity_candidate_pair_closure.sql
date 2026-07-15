with current_run as (
    select identity_run_key
    from {{ ref('int_identity_current_run') }}
),

rule_hit_counts as (
    select
        candidate_pair_key,
        count(*) as rule_hit_count
    from {{ ref('identity_candidate_rule_hit') }}
    inner join current_run using (identity_run_key)
    group by candidate_pair_key
),

invalid_pairs as (
    select pair.candidate_pair_key
    from {{ ref('identity_candidate_pair') }} as pair
    inner join current_run on pair.identity_run_key = current_run.identity_run_key
left join rule_hit_counts using (candidate_pair_key)
where
    pair.run_observation_key_l >= pair.run_observation_key_r
    or rule_hit_counts.rule_hit_count is null
    or pair.blocking_rule_count <> rule_hit_counts.rule_hit_count
),

orphan_rule_hits as (
select rule_hit.candidate_pair_key
from {{ ref('identity_candidate_rule_hit') }} as rule_hit
inner join current_run on rule_hit.identity_run_key = current_run.identity_run_key
left join {{ ref('identity_candidate_pair') }} as pair using (candidate_pair_key)
where pair.candidate_pair_key is null
)

select
'INVALID_PAIR' as issue_type,
candidate_pair_key
from invalid_pairs
union all
select
'ORPHAN_RULE_HIT',
candidate_pair_key
from orphan_rule_hits
