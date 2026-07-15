{% macro epc_rating_for_score(expression) -%}
    case
        when {{ expression }} is null then null
        when {{ expression }} >= 92 then 'A'
        when {{ expression }} >= 81 then 'B'
        when {{ expression }} >= 69 then 'C'
        when {{ expression }} >= 55 then 'D'
        when {{ expression }} >= 39 then 'E'
        when {{ expression }} >= 21 then 'F'
        else 'G'
    end
{%- endmacro %}
