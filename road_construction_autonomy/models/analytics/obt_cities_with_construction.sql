-- CREATE OR REPLACE TABLE obt_top_cities_with_construction AS

-- severity is the construction's impact on traffic: 1 (short delay) to 4 (long delay); 3 and 4 are high severity
{% set high_severity_levels = [3, 4] %}

SELECT
    EXTRACT(YEAR FROM fc.start_time_local) AS year,
    EXTRACT (Month FROM fc.start_time_local) AS month,
	fc.city,
	fc.county,
	fc.state,
    dtc.population AS city_population, -- null for city that is not in the top 10 cities by population
    dtc.land_area_sq_mi AS city_land_area_sq_mi, -- null for city that is not in the top 10 cities by population    
	ROUND(SUM(TIMESTAMP_DIFF(fc.end_time_local, fc.start_time_local, SECOND)) / 3600.0, 2) AS construction_hours,
    ROUND(SUM(fc.distance_mi), 2) AS total_distance_mi,
    COUNT(fc.construction_id) AS construction_count,
    COUNTIF(fc.severity IN ({{ high_severity_levels | join(', ') }})) AS construction_count_high_severity
FROM {{ ref('fact_construction') }} fc
LEFT JOIN {{ ref('dim_top_10_cities_population') }} dtc 
    ON fc.city = dtc.city AND fc.state = dtc.state
-- data over the past 5 year from 2027 to 2021
WHERE DATE(fc.start_time_local) >= DATE('2017-01-01')
    AND DATE(fc.start_time_local) < DATE('2022-01-01')
GROUP BY year, month, fc.city, fc.county, fc.state, dtc.population, dtc.land_area_sq_mi
