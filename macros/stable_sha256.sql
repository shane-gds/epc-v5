{% macro stable_sha256_component(expression) -%}
    case
        when {{ expression }} is null then 'N;'
        else concat(
            'V',
            lpad(cast(octet_length(encode(cast({{ expression }} as varchar))) as varchar), 20, '0'),
            ':',
            cast({{ expression }} as varchar),
            ';'
        )
    end
{%- endmacro %}

{% macro stable_sha256(key_namespace, payload_version, fields) -%}
    sha256(concat(
        'SK1;',
        'NS=', {{ stable_sha256_component("'" ~ key_namespace ~ "'") }},
        'PV=', {{ stable_sha256_component("'" ~ payload_version ~ "'") }}
        {%- for field in fields %},
        'P', lpad('{{ loop.index }}', 20, '0'), '=',
        {{ stable_sha256_component(field) }}
        {%- endfor %}
    ))
{%- endmacro %}
