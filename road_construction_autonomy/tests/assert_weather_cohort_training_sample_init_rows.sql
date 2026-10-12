-- once the notebook has written the init seed, exactly k training rows must be flagged as init centroids
SELECT init_rows
FROM (SELECT COUNTIF(is_init_centroid) AS init_rows FROM {{ ref('int_weather_cohort_training_sample') }})
WHERE init_rows != {{ var('weather_cohort_k') }}
  AND (SELECT COUNT(*) FROM {{ ref('weather_cohort_init_centroids') }}) > 0
