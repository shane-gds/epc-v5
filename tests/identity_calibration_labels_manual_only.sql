select
    adjudication_label_id,
    label_source,
    label_status
from {{ source('identity_calibration', 'identity_adjudication_label') }}
where label_source <> 'MANUAL'
   or label_status not in ('ACTIVE', 'SUPERSEDED')
