{{ config(materialized='view', tags=['identity', 'splink', 'decision']) }}

with scoring_publication as (
    select *
    from {{ source('identity_scoring', 'identity_splink_publication') }}
)

select score.*
from {{ source('identity_scoring', 'identity_match_score') }} as score
inner join scoring_publication
    on
        score.identity_run_key = scoring_publication.identity_run_key
        and score.splink_run_id = scoring_publication.splink_run_id
        and score.model_sha256 = scoring_publication.model_sha256
inner join {{ ref('int_identity_current_run') }} as current_run
    on scoring_publication.identity_run_key = current_run.identity_run_key
inner join {{ source('identity_scoring', 'identity_splink_run') }} as splink_run
    on
        scoring_publication.splink_run_id = splink_run.splink_run_id
        and scoring_publication.identity_run_key = splink_run.identity_run_key
        and scoring_publication.model_sha256 = splink_run.model_sha256
        and splink_run.run_mode = 'NATIONAL'
        and splink_run.run_status = 'SUCCEEDED'
