-- one scored row per construction event (dbt_utils is not installed, so no equal_rowcount)
SELECT fact_rows, impact_rows
FROM (
    SELECT
        (SELECT COUNT(*) FROM {{ ref('fact_construction') }}) AS fact_rows,
        (SELECT COUNT(*) FROM {{ ref('fact_construction_weather_impact') }}) AS impact_rows
)
WHERE fact_rows != impact_rows
