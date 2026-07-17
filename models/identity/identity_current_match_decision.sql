{{ config(materialized='view', tags=['identity', 'decision']) }}

with scoring_publication as (
    select *
    from {{ source('identity_scoring', 'identity_splink_publication') }}
)

select decision.*
from {{ ref('identity_match_decision') }} as decision
inner join scoring_publication
    on
        decision.identity_run_key = scoring_publication.identity_run_key
        and decision.splink_run_id = scoring_publication.splink_run_id
        and decision.model_sha256 = scoring_publication.model_sha256
inner join {{ ref('int_identity_current_run') }} as current_run
    on scoring_publication.identity_run_key = current_run.identity_run_key
