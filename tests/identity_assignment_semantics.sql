select
    assignment_key,
    assignment_status,
    assignment_method,
    assignment_confidence,
    assignment_confidence_basis,
    registry_entity_id,
    hypothesis_outcome,
    registry_promotion_status,
    reason_codes
from {{ ref('bridge_source_record_entity_assignment') }}
where is_current
  and (
      assignment_status is distinct from 'UNRESOLVED'
      or registry_entity_id is not null
      or assignment_confidence is not null
      or assignment_confidence_basis is distinct from 'NOT_AVAILABLE_UNCALIBRATED'
      or registry_promotion_status is distinct from 'NOT_PROMOTED_UNCALIBRATED'
      or reason_codes is null
      or list_contains(reason_codes, 'UNCALIBRATED_POLICY') is distinct from true
      or list_contains(reason_codes, 'REGISTRY_NOT_PROMOTED') is distinct from true
      or (
          hypothesis_outcome = 'SINGLETON_NO_CANDIDATE'
          and (
              assignment_method is distinct from 'NO_CANDIDATE_SINGLETON'
              or list_contains(reason_codes, 'NO_CANDIDATE') is distinct from true
          )
      )
      or (
          hypothesis_outcome = 'UNRESOLVED_REVIEW'
          and (
              assignment_method is distinct from 'UNCALIBRATED_REVIEW_REQUIRED'
              or list_contains(reason_codes, 'CANDIDATE_REVIEW_REQUIRED')
                  is distinct from true
          )
      )
      or hypothesis_outcome is null
      or assignment_method is null
      or (assignment_confidence is not null and assignment_confidence not between 0 and 1)
  )
