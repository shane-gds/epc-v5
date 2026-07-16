{% macro identity_assignment_publication_action(
    assignment_count,
    current_assignment_count,
    eligible_count
) -%}
    case
        when {{ assignment_count }} > 0 and {{ current_assignment_count }} = 0
            then 'REACTIVATION_BLOCKED'
        when
            {{ assignment_count }} > 0
            and (
                {{ assignment_count }} <> {{ eligible_count }}
                or {{ current_assignment_count }} <> {{ eligible_count }}
            )
            then 'INCOMPLETE_BLOCKED'
        when {{ assignment_count }} = 0 then 'PUBLISH'
        else 'NO_OP'
    end
{%- endmacro %}


{% macro identity_assignment_prepublication_action(
    existing_assignment_count,
    proposed_assignment_count,
    eligible_count
) -%}
    case
        when
            {{ existing_assignment_count }} = 0
            and {{ proposed_assignment_count }} <> {{ eligible_count }}
            then 'INCOMPLETE_BLOCKED'
        else 'PASS'
    end
{%- endmacro %}


{% macro assert_identity_assignment_prepublication_completeness() -%}
    with selected_run as (
        select identity_run_key
        from {{ ref('int_identity_current_run') }}
    ),

    existing_profile as (
        {% if is_incremental() %}
            select count(*) as existing_assignment_count
            from {{ adapter.quote(target.database) }}.{{ adapter.quote('identity') }}.{{ adapter.quote(this.identifier) }} as assignment
            inner join selected_run using (identity_run_key)
        {% else %}
            select 0::ubigint as existing_assignment_count
        {% endif %}
    ),

    eligible_profile as (
        select count(*) as eligible_count
        from {{ ref('int_identity_observation') }} as observation
        inner join selected_run using (identity_run_key)
        where observation.is_identity_eligible
    ),

    proposed_profile as (
        select count(*) as proposed_assignment_count
        from {{ ref('int_identity_observation') }} as observation
        inner join {{ ref('identity_hypothesis') }} as hypothesis
            on
                observation.identity_run_key = hypothesis.identity_run_key
                and observation.identity_run_observation_key
                = hypothesis.identity_run_observation_key
        inner join selected_run
            on observation.identity_run_key = selected_run.identity_run_key
        where observation.is_identity_eligible
    )

    select case {{ identity_assignment_prepublication_action(
        'existing_profile.existing_assignment_count',
        'proposed_profile.proposed_assignment_count',
        'eligible_profile.eligible_count'
    ) }}
        when 'INCOMPLETE_BLOCKED'
            then error('Proposed assignment publication does not cover all eligible records')
        else true
    end as assignment_prepublication_is_complete
    from existing_profile
    cross join eligible_profile
    cross join proposed_profile
{%- endmacro %}
