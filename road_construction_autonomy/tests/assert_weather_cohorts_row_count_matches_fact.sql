-- every construction event gets a cohort, including precip_type = unknown
SELECT fact_rows, cohort_rows
FROM (
    SELECT
        (SELECT COUNT(*) FROM {{ ref('fact_construction') }}) AS fact_rows,
        (SELECT COUNT(*) FROM {{ ref('int_construction_weather_cohorts') }}) AS cohort_rows
)
WHERE fact_rows != cohort_rows
