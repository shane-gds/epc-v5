{% macro uk_postcode_compact(expression) -%}
    upper(regexp_replace(trim(cast({{ expression }} as varchar)), '\s+', '', 'g'))
{%- endmacro %}

{% macro uk_postcode_is_valid(expression) -%}
    regexp_full_match(
        {{ uk_postcode_compact(expression) }},
        '(GIR0AA|[A-PR-UWYZ][0-9][0-9A-HJKSTUW]?|[A-PR-UWYZ][A-HK-Y][0-9][0-9ABEHMNPRVWXY]?)[0-9][ABD-HJLNP-UW-Z]{2}'
    )
{%- endmacro %}

{% macro normalise_uk_postcode(expression) -%}
    case
        when nullif(trim(cast({{ expression }} as varchar)), '') is null then null
        when {{ uk_postcode_is_valid(expression) }} then concat(
            left(
                {{ uk_postcode_compact(expression) }},
                length({{ uk_postcode_compact(expression) }}) - 3
            ),
            ' ',
            right({{ uk_postcode_compact(expression) }}, 3)
        )
        else null
    end
{%- endmacro %}

{% macro uk_postcode_parse_status(expression) -%}
    case
        when nullif(trim(cast({{ expression }} as varchar)), '') is null then 'MISSING'
        when {{ uk_postcode_is_valid(expression) }} then 'VALID'
        else 'INVALID'
    end
{%- endmacro %}

{% macro uk_postcode_sector(expression) -%}
    case
        when {{ normalise_uk_postcode(expression) }} is null then null
        else concat(
            split_part({{ normalise_uk_postcode(expression) }}, ' ', 1),
            ' ',
            left(split_part({{ normalise_uk_postcode(expression) }}, ' ', 2), 1)
        )
    end
{%- endmacro %}
