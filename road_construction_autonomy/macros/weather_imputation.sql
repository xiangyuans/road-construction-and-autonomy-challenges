{#
    Set-based helpers for int_construction_weather_imputed.

    exact_group_medians: exact median (same result as PERCENTILE_CONT(x, 0.5)) of each
    field per group, computed from cumulative counts of distinct values. This avoids
    one huge analytic window per field (the overall-median level would otherwise put
    all ~6M rows in one partition). NULLs are ignored (UNPIVOT excludes them).
    Returns: <keys>, n_<field>, median_<field> for every field.

    group_mode: most frequent non-null value per group (ties -> alphabetical first),
    with the group's total non-null count.
    Returns: <keys>, mode_value, total_count.
#}

{% macro exact_group_medians(source, keys, fields) %}
{%- set key_list = keys | join(', ') -%}
SELECT
    {{ key_list }},
    {%- for f in fields %}
    MAX(IF(field_name = '{{ f }}', n_values, NULL)) AS n_{{ f }},
    MAX(IF(field_name = '{{ f }}', median_value, NULL)) AS median_{{ f }}{{ ',' if not loop.last }}
    {%- endfor %}
FROM (
    SELECT
        {{ key_list }},
        field_name,
        n_values,
        (
            MIN(IF(cum_count >= DIV(n_values + 1, 2), field_value, NULL))
            + MIN(IF(cum_count >= DIV(n_values, 2) + 1, field_value, NULL))
        ) / 2 AS median_value
    FROM (
        SELECT
            {{ key_list }},
            field_name,
            field_value,
            SUM(value_count) OVER (PARTITION BY {{ key_list }}, field_name ORDER BY field_value) AS cum_count,
            SUM(value_count) OVER (PARTITION BY {{ key_list }}, field_name) AS n_values
        FROM (
            SELECT {{ key_list }}, field_name, field_value, COUNT(*) AS value_count
            FROM {{ source }}
            UNPIVOT (field_value FOR field_name IN ({{ fields | join(', ') }}))
            GROUP BY {{ key_list }}, field_name, field_value
        )
    )
    GROUP BY {{ key_list }}, field_name, n_values
)
GROUP BY {{ key_list }}
{% endmacro %}


{% macro group_mode(source, keys, field) %}
{%- set key_list = keys | join(', ') -%}
SELECT {{ key_list }}, mode_value, total_count
FROM (
    SELECT
        {{ key_list }},
        {{ field }} AS mode_value,
        SUM(value_count) OVER (PARTITION BY {{ key_list }}) AS total_count,
        ROW_NUMBER() OVER (PARTITION BY {{ key_list }} ORDER BY value_count DESC, {{ field }}) AS value_rank
    FROM (
        SELECT {{ key_list }}, {{ field }}, COUNT(*) AS value_count
        FROM {{ source }}
        WHERE {{ field }} IS NOT NULL
        GROUP BY {{ key_list }}, {{ field }}
    )
)
WHERE value_rank = 1
{% endmacro %}
