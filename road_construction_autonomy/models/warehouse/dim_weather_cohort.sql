{{ config(materialized='table') }}

{#-
    One row per cohort label in fact_construction_weather_impact (the 9 weather cohorts plus Unknown for
    precip_type = unknown): size, average weather profile and mean self-driving impact score.
-#}

WITH cohorts AS (
    SELECT *
    FROM {{ ref('int_construction_weather_cohorts') }}
),

impact AS (
    SELECT construction_id, self_driving_impact_score, self_driving_impact_level, cohort_label
    FROM {{ ref('fact_construction_weather_impact') }}
),

profile AS (
    SELECT
        -- Unknown has no cohort of its own; the weather cohorts map 1:1 to a BigQuery ML centroid
        MAX(IF(impact.cohort_label = 'Unknown', NULL, cohorts.cohort_id)) AS cohort_id,
        impact.cohort_label,
        COUNT(*) AS row_count,
        COUNT(*) / SUM(COUNT(*)) OVER () AS population_share,
        AVG(cohorts.precipitation_inches_capped) AS avg_precipitation_inches_capped,
        AVG(cohorts.visibility_miles_clipped) AS avg_visibility_miles_clipped,
        AVG(cohorts.wind_speed_mph_clipped) AS avg_wind_speed_mph_clipped,
        AVG(cohorts.humidity_percent) AS avg_humidity_percent,
        AVG(cohorts.temperature_fahrenheit_clipped) AS avg_temperature_fahrenheit_clipped,
        AVG(IF(cohorts.wet_road, 1, 0)) AS share_wet_road,
        AVG(IF(cohorts.freezing_wet, 1, 0)) AS share_freezing_wet,
        AVG(IF(cohorts.is_blowing, 1, 0)) AS share_blowing,
        AVG(IF(cohorts.is_night, 1, 0)) AS share_night,
        AVG(IF(cohorts.precip_intensity = 'heavy', 1, 0)) AS share_heavy_precip,
        AVG(IF(cohorts.precip_type = 'unknown', 1, 0)) AS share_unknown_precip_type,
        AVG(IF(cohorts.ambiguous_cohort, 1, 0)) AS share_ambiguous,
        APPROX_TOP_COUNT(cohorts.precip_type, 1)[OFFSET(0)].value AS dominant_precip_type,
        AVG(impact.self_driving_impact_score) AS mean_self_driving_impact_score,
        AVG(IF(impact.self_driving_impact_level IN ('High', 'Severe'), 1, 0)) AS share_high_or_severe
    FROM cohorts
    INNER JOIN impact USING (construction_id)
    GROUP BY impact.cohort_label
)

SELECT
    RANK() OVER (ORDER BY mean_self_driving_impact_score DESC) AS impact_rank,
    *
FROM profile
