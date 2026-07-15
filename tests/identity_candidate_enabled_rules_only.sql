select rule_hit.*
from {{ ref('identity_candidate_rule_hit') }} as rule_hit
left join {{ ref('identity_blocking_policy') }} as policy
    on
        rule_hit.policy_version = policy.policy_version
        and rule_hit.rule_code = policy.rule_code
where
    policy.rule_code is null
    or not policy.enabled
    or policy.evidence_class in ('BENCHMARK', 'PROHIBITED')
