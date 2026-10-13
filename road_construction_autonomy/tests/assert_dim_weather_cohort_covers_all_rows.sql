-- cohort row counts must add up to all construction events
SELECT total
FROM (SELECT SUM(row_count) AS total FROM {{ ref('dim_weather_cohort') }})
WHERE total != (SELECT COUNT(*) FROM {{ ref('fact_construction') }})
