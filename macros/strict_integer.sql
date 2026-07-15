{% macro try_strict_unsigned_integer(expression, data_type='ubigint') -%}
    case
        when regexp_full_match(trim(cast({{ expression }} as varchar)), '^[0-9]+$')
            then try_cast(trim(cast({{ expression }} as varchar)) as {{ data_type }})
    end
{%- endmacro %}

{% macro try_strict_integer(expression, data_type='integer') -%}
    case
        when regexp_full_match(trim(cast({{ expression }} as varchar)), '^-?[0-9]+$')
            then try_cast(trim(cast({{ expression }} as varchar)) as {{ data_type }})
    end
{%- endmacro %}
