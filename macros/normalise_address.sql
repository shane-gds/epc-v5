{% macro normalise_address(expression) -%}
    nullif(
        trim(
            regexp_replace(
                regexp_replace(upper(cast({{ expression }} as varchar)), '[^A-Z0-9]+', ' ', 'g'),
                '\s+',
                ' ',
                'g'
            )
        ),
        ''
    )
{%- endmacro %}
