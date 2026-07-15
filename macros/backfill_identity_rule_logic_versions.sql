{% macro backfill_identity_rule_logic_versions() %}
    {% set update_sql %}
        update identity.identity_candidate_rule_hit as rule_hit
        set rule_logic_version = case rule_hit.rule_code
            when 'D01_EXACT_UPRN' then 'd01_v1'
            when 'P01_POSTCODE_PREMISE_EXACT' then 'p01_v1'
            when 'P02_SECTOR_PREMISE_EXACT' then case
                when rule_hit.identity_run_key = (
                    select identity_run_key from identity.int_identity_current_run
                ) then 'p02_v2'
                else 'p02_v1'
            end
        end
        where rule_hit.rule_logic_version is null
    {% endset %}
    {% do run_query(update_sql) %}
{% endmacro %}
