{{ config(materialized='view', tags=['identity', 'cluster']) }}

select
    hypothesis.identity_cluster_key,
    hypothesis.identity_hypothesis_key,
    hypothesis.identity_run_id,
    hypothesis.identity_run_key,
    hypothesis.identity_run_observation_key,
    hypothesis.identity_observation_key,
    'SINGLETON' as cluster_kind,
    false as is_registry_promoted,
    case hypothesis.hypothesis_outcome
        when 'SINGLETON_NO_CANDIDATE' then 'SINGLETON'
        else 'UNRESOLVED_REVIEW'
    end as membership_status
from {{ ref('identity_hypothesis') }} as hypothesis
inner join {{ ref('int_identity_current_run') }} as current_run
    on hypothesis.identity_run_key = current_run.identity_run_key
