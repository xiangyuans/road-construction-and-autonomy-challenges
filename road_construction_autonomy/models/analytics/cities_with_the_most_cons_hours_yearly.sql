WITH total_construction_hours AS (
SELECT
  year,
  city,
  state,
  ROUND(SUM(construction_hours), 2) AS construction_hours,
  SUM(construction_count) AS construction_count,
  SUM(construction_count_high_severity) AS construction_count_high_severity
FROM {{ ref('obt_cities_with_construction') }}
GROUP BY 1, 2, 3
), 

ranked_construction_hours AS (

SELECT
  year,
  city,
  state,
  construction_hours,
  construction_count,
  construction_count_high_severity,
  DENSE_RANK() OVER (PARTITION BY year ORDER BY construction_hours DESC) AS construction_hours_rank
FROM total_construction_hours
)

SELECT
  year,
  city,
  state,
  construction_hours,
  construction_count,
  construction_count_high_severity,
  ROUND(SAFE_DIVIDE(construction_count_high_severity, construction_count), 2) AS high_severity_pct,
  ROUND(SAFE_DIVIDE(construction_hours, construction_count), 2) AS hours_per_construction
FROM ranked_construction_hours
WHERE construction_hours_rank =1