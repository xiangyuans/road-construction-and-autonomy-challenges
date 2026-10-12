-- nearest / second-nearest distance ratio must be between 0 and 1
SELECT construction_id, centroid_distance_ratio
FROM {{ ref('int_construction_weather_cohorts') }}
WHERE centroid_distance_ratio IS NULL OR centroid_distance_ratio NOT BETWEEN 0 AND 1
