-- Reproduces every component of self_driving_impact_score for chosen construction events, for spot checks.
-- Usage:
--   dbt compile --select weather_impact_score_breakdown --vars '{breakdown_construction_ids: ["C-2734422", "C-281268"]}'
--   then run the compiled SQL from target/compiled/.../analyses/weather_impact_score_breakdown.sql in BigQuery.
-- Uses the same macro as fact_construction_weather_impact, so the components match the stored score.

{%- set ids = var('breakdown_construction_ids', ['C-2734422', 'C-281268', 'C-3050550']) %}

WITH cohorts AS (
    SELECT *
    FROM {{ ref('int_construction_weather_cohorts') }}
    WHERE construction_id IN ({% for i in ids %}'{{ i }}'{{ ', ' if not loop.last }}{% endfor %})
),

{{ weather_impact_ctes('cohorts') }}

SELECT
    scored.construction_id,
    scored.cohort_label,
    scored.precip_type,
    scored.precip_intensity,
    scored.visibility_miles_clipped,
    scored.wind_speed_mph_clipped,
    scored.temperature_fahrenheit_clipped,
    scored.wet_road,
    scored.freezing_wet,
    scored.is_freezing,
    scored.is_precipitating,
    scored.is_night,
    scored.is_blowing,
    scored.visibility_hazard,
    scored.precip_sensor_hazard,
    scored.traction_hazard,
    scored.hazard_driver,
    scored.worst_hazard,
    scored.second_hazard,
    scored.base_score,
    scored.darkness_add,
    scored.wind_add,
    scored.blowing_add,
    scored.self_driving_impact_score,
    {{ weather_impact_level('scored.self_driving_impact_score') }} AS self_driving_impact_level,
    stored.self_driving_impact_score AS stored_score,
    stored.self_driving_impact_level AS stored_level
FROM scored
LEFT JOIN {{ ref('fact_construction_weather_impact') }} AS stored
    USING (construction_id)
ORDER BY scored.construction_id
