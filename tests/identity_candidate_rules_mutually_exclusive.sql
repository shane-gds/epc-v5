select
    candidate_pair_key,
    count(*) as rule_hit_count
from {{ ref('identity_candidate_rule_hit') }} as rule_hit
inner join {{ ref('int_identity_current_run') }} as current_run
    on rule_hit.identity_run_key = current_run.identity_run_key
group by candidate_pair_key
having count(*) <> 1
