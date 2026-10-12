{{ config(materialized='table') }}

{#-
    Derives precipitation type/intensity and road-condition flags from the imputed weather.
    The exploration notebook samples from this model, so clustering features match production.
-#}

{%- set light_max = var('weather_precip_light_max_in') -%}
{%- set heavy_min = var('weather_precip_heavy_min_in') -%}
{%- set freezing_f = var('weather_freezing_threshold_f') -%}

WITH imputed AS (
    SELECT *
    FROM {{ ref('int_construction_weather_imputed') }}
),

seed AS (
    SELECT *
    FROM {{ ref('weather_condition_mapping') }}
),

joined AS (
    SELECT
        imputed.*,
        seed.precip_type AS seed_precip_type,
        seed.precip_intensity AS seed_precip_intensity,
        seed.is_precipitating AS seed_is_precipitating,
        COALESCE(seed.is_windy, FALSE) AS is_windy,
        COALESCE(seed.is_blowing, FALSE) AS is_blowing,
        COALESCE(seed.is_freezing, FALSE) AS is_freezing,
        -- numeric fallback: condition still missing, or "n/a precipitation" (unknown type but precipitating)
        (
            seed.precip_type IS NULL
            OR (seed.precip_type = 'unknown' AND seed.is_precipitating)
        ) AS use_numeric_fallback
    FROM imputed
    LEFT JOIN seed
        ON seed.weather_condition = imputed.weather_condition
),

typed AS (
    SELECT
        *,
        CASE
            WHEN NOT use_numeric_fallback THEN seed_precip_type
            WHEN precipitation_inches > 0 AND temperature_fahrenheit <= 32 THEN 'snow'
            WHEN precipitation_inches > 0 AND temperature_fahrenheit > 32 THEN 'rain'
            ELSE 'unknown'
        END AS precip_type,
        IF(use_numeric_fallback, 'inferred_from_numeric', 'condition_text') AS precip_type_source,
        COALESCE(precipitation_inches > 0, FALSE) AS wet_road
    FROM joined
)

SELECT
    construction_id,
    weather_timestamp,
    EXTRACT(HOUR FROM weather_timestamp) AS weather_hour_of_day,
    weather_condition,
    temperature_fahrenheit,
    humidity_percent,
    visibility_miles,
    wind_speed_mph,
    precipitation_inches,
    -- plausible extremes clipped for clustering and scoring (impossible values were nulled upstream)
    LEAST(GREATEST(temperature_fahrenheit, {{ var('weather_temperature_clip_min_f') }}), {{ var('weather_temperature_clip_max_f') }}) AS temperature_fahrenheit_clipped,
    LEAST(GREATEST(visibility_miles, {{ var('weather_visibility_clip_min_mi') }}), {{ var('weather_visibility_clip_max_mi') }}) AS visibility_miles_clipped,
    LEAST(GREATEST(wind_speed_mph, {{ var('weather_wind_clip_min_mph') }}), {{ var('weather_wind_clip_max_mph') }}) AS wind_speed_mph_clipped,
    precipitation_inches_capped,
    precip_invalid,
    temperature_invalid,
    visibility_invalid,
    wind_speed_invalid,
    precip_type,
    precip_type_source,
    CASE
        -- the text states the intensity (or says nothing is falling)
        WHEN seed_precip_intensity IS NOT NULL THEN seed_precip_intensity
        -- text says it is precipitating but gives no intensity: never "none"
        WHEN seed_is_precipitating AND precipitation_inches_capped < {{ light_max }} THEN 'light'
        WHEN precipitation_inches_capped = 0 THEN 'none'
        WHEN precipitation_inches_capped < {{ light_max }} THEN 'light'
        WHEN precipitation_inches_capped <= {{ heavy_min }} THEN 'moderate'
        ELSE 'heavy'
    END AS precip_intensity,
    is_windy,
    is_blowing,
    is_freezing,
    seed_is_precipitating AS is_precipitating,
    COALESCE(seed_is_precipitating = FALSE AND precipitation_inches > 0, FALSE) AS precip_conflict,
    wet_road,
    (
        is_freezing
        OR (
            temperature_fahrenheit <= {{ freezing_f }}
            AND (wet_road OR precip_type IN ('snow', 'ice_freezing'))
        )
    ) AS freezing_wet,
    (
        EXTRACT(HOUR FROM weather_timestamp) >= {{ var('weather_night_start_hour') }}
        OR EXTRACT(HOUR FROM weather_timestamp) < {{ var('weather_night_end_hour') }}
    ) AS is_night,
    impute_source,
    imputed_fields
FROM typed
