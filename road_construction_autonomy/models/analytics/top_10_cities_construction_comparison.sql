WITH total_construction_hours AS (
SELECT
  city,
  state,
  city_population,
  city_land_area_sq_mi,
  ROUND(SUM(construction_hours), 2) AS construction_hours,
  ROUND(SUM(construction_hours * total_distance_mi), 2) AS mile_hours,
  SUM(construction_count) AS construction_count,
  SUM(construction_count_high_severity) AS construction_count_high_severity
FROM {{ ref('obt_cities_with_construction') }}
WHERE city_population IS NOT NULL -- only include the top 10 largest cities
GROUP BY 1, 2, 3, 4
), 

ranked_construction_hours AS (

SELECT
  city,
  state,
  city_population,
  city_land_area_sq_mi,
  construction_count, --raw construction count
  ROUND(construction_count*1000.0/city_population, 2) AS construction_count_per_1k_pop, -- normalized by population
  construction_hours, -- raw construction hours
  ROUND(construction_hours*1000.0/city_population, 2) AS construction_hours_per_1k_pop, -- normalized by population
  ROUND(construction_hours/city_land_area_sq_mi, 2) AS construction_hours_per_sq_mi, -- normalized by sq mi
  ROUND(mile_hours/city_land_area_sq_mi, 2) AS mile_hours_per_sq_mi --taking mile and hours into cosideration and normalized by sq mi
FROM total_construction_hours
)

SELECT
  city,
  state,
  city_population,
  city_land_area_sq_mi,
  construction_count,
  construction_count_per_1k_pop,
  construction_hours,
  construction_hours_per_1k_pop,
  construction_hours_per_sq_mi,
  mile_hours_per_sq_mi
FROM ranked_construction_hours