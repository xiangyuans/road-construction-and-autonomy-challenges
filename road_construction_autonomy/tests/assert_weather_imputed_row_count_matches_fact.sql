-- imputation must not drop or duplicate rows (dbt_utils is not installed, so no equal_rowcount)
SELECT fact_rows, imputed_rows
FROM (
    SELECT
        (SELECT COUNT(*) FROM {{ ref('fact_construction') }}) AS fact_rows,
        (SELECT COUNT(*) FROM {{ ref('int_construction_weather_imputed') }}) AS imputed_rows
)
WHERE fact_rows != imputed_rows
