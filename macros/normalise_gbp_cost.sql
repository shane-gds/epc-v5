{% macro normalise_gbp_cost_text(expression) -%}
    nullif(trim(cast({{ expression }} as varchar)), '')
{%- endmacro %}

{% macro gbp_cost_numeric_text(expression) -%}
    regexp_replace(
        upper({{ normalise_gbp_cost_text(expression) }}),
        '(GBP|£|,|\s)',
        '',
        'g'
    )
{%- endmacro %}
