with fixtures as (
    select *
    from (values
        ('NEW_RUN', 0, 0, 5, 'PUBLISH'),
        ('COMPLETE_CURRENT_RUN', 5, 5, 5, 'NO_OP'),
        ('PARTIAL_CURRENT_RUN', 3, 3, 5, 'INCOMPLETE_BLOCKED'),
        ('MIXED_CURRENT_RUN', 5, 3, 5, 'INCOMPLETE_BLOCKED'),
        ('HISTORICAL_REACTIVATION', 5, 0, 5, 'REACTIVATION_BLOCKED')
    ) as fixture(
        fixture_name,
        assignment_count,
        current_assignment_count,
        eligible_count,
        expected_action
    )
),

evaluated as (
    select
        *,
        {{ identity_assignment_publication_action(
            'assignment_count',
            'current_assignment_count',
            'eligible_count'
        ) }} as actual_action
    from fixtures
),

prepublication_fixtures as (
    select *
    from (values
        ('ZERO_PROPOSED', 0, 0, 5, 'INCOMPLETE_BLOCKED'),
        ('PARTIAL_PROPOSED', 0, 3, 5, 'INCOMPLETE_BLOCKED'),
        ('COMPLETE_PROPOSED', 0, 5, 5, 'PASS'),
        ('EXISTING_ATOMIC_RUN', 5, 0, 5, 'PASS')
    ) as fixture(
        fixture_name,
        existing_assignment_count,
        proposed_assignment_count,
        eligible_count,
        expected_action
    )
),

prepublication_evaluated as (
    select
        *,
        {{ identity_assignment_prepublication_action(
            'existing_assignment_count',
            'proposed_assignment_count',
            'eligible_count'
        ) }} as actual_action
    from prepublication_fixtures
)

select fixture_name, expected_action, actual_action
from evaluated
where actual_action is distinct from expected_action

union all

select fixture_name, expected_action, actual_action
from prepublication_evaluated
where actual_action is distinct from expected_action
