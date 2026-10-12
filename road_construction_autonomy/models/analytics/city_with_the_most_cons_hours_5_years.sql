WITH total_construction_hours AS (
SELECT
  city,
  state,
  ROUND(SUM(construction_hours), 2) AS construction_hours,
  ROUND(SUM(construction_hours)/5.0, 2) AS yearly_construction_hours
FROM {{ ref('obt_cities_with_construction') }}
GROUP BY 1, 2
), 

ranked_construction_hours AS (

SELECT
  city,
  state,
  construction_hours,
  yearly_construction_hours,
  DENSE_RANK() OVER (ORDER BY construction_hours DESC) AS construction_hours_rank
FROM total_construction_hours
)

SELECT
  city,
  state,
  construction_hours,
  yearly_construction_hours
FROM ranked_construction_hours
WHERE construction_hours_rank =1