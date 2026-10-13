{{ config(
    materialized='table',
    pre_hook="{{ train_weather_cohort_model() }}"
) }}

{#-
    Assigns every construction event (including precip_type = unknown) to its nearest weather cohort with the
    saved BigQuery ML k-means model (trained by the pre-hook only when var refit_cohort_model is true, or when
    no model exists yet). Cohort labels come from rules on each cluster's average profile, the same rules as
    the exploration notebook, so they stay stable across refits.
-#}

{% set share = var('weather_cohort_label_share') %}

-- depends_on: {{ ref('int_weather_cohort_training_sample') }}
-- depends_on: {{ ref('weather_cohort_init_centroids') }}

WITH features AS (
    SELECT
        construction_id,
        precip_type,
        precip_type_source,
        precip_intensity,
        precipitation_inches_capped,
        visibility_miles_clipped,
        wind_speed_mph_clipped,
        humidity_percent,
        temperature_fahrenheit_clipped,
        wet_road,
        freezing_wet,
        is_freezing,
        is_precipitating,
        is_blowing,
        is_night,
        impute_source,
        {{ weather_cohort_feature_columns() }}
    FROM {{ ref('int_construction_weather_features') }}
),

predicted AS (
    SELECT
        * EXCEPT (centroid_id, nearest_centroids_distance),
        centroid_id AS cohort_id,
        (SELECT MIN(d.distance) FROM UNNEST(nearest_centroids_distance) AS d) AS centroid_distance,
        (SELECT d.distance FROM UNNEST(nearest_centroids_distance) AS d ORDER BY d.distance LIMIT 1 OFFSET 1) AS second_centroid_distance
    FROM ML.PREDICT(MODEL {{ weather_cohort_model_relation() }}, (SELECT * FROM features))
),

-- average profile per cluster over rows with a known precip_type (the population the model was trained on)
cluster_profile AS (
    SELECT
        cohort_id,
        COUNT(*) AS cluster_rows,
        {%- for t in weather_cohort_precip_types() %}
        AVG(feat_type_{{ t }}) AS share_{{ t }},
        {%- endfor %}
        AVG(IF(precip_intensity = 'heavy', 1, 0)) AS share_heavy_precip,
        AVG(IF(precip_type = 'fog' AND visibility_miles_clipped < {{ var('weather_cohort_dense_fog_max_mi') }}, 1, 0)) AS share_dense_fog,
        AVG(IF(wind_speed_mph_clipped >= {{ var('weather_cohort_high_wind_mph') }}, 1, 0)) AS share_high_wind,
        AVG(feat_is_blowing) AS share_blowing,
        AVG(feat_freezing_wet) AS share_freezing_wet,
        AVG(feat_is_night) AS share_night
    FROM predicted
    WHERE precip_type != 'unknown'
    GROUP BY cohort_id
),

-- same rules and order as label_cluster() in the notebook
cluster_base_label AS (
    SELECT
        cohort_id,
        cluster_rows,
        CASE
            WHEN share_ice_freezing >= {{ share }} THEN 'Freezing/Icy'
            WHEN share_snow >= {{ share }} THEN IF(share_heavy_precip >= {{ share }}, 'Heavy Snow', 'Snow')
            WHEN share_thunderstorm >= {{ share }} THEN IF(share_heavy_precip >= {{ share }}, 'Heavy Thunderstorm', 'Thunderstorm')
            WHEN share_rain >= {{ share }} THEN IF(share_heavy_precip >= {{ share }}, 'Heavy Rain', 'Rain')
            WHEN share_fog >= {{ share }} THEN IF(share_dense_fog >= {{ share }}, 'Dense Fog', 'Fog/Low Visibility')
            WHEN share_blowing >= {{ share }} OR share_high_wind >= {{ share }} THEN 'High Wind/Blowing'
            WHEN share_haze_smoke_dust >= {{ share }} THEN 'Haze/Smoke/Dust'
            WHEN share_clear_cloudy >= {{ share }} THEN IF(share_night >= {{ share }}, 'Clear/Dry Night', 'Clear/Dry Day')
            WHEN share_heavy_precip >= {{ share }} THEN 'Heavy Precipitation'
            WHEN share_freezing_wet >= {{ share }} THEN 'Freezing/Icy'
            ELSE 'Mixed'
        END AS base_label
    FROM cluster_profile
),

-- duplicate names get a numeric suffix, the largest cluster keeping the plain name
cluster_label AS (
    SELECT
        cohort_id,
        IF(
            ROW_NUMBER() OVER (PARTITION BY base_label ORDER BY cluster_rows DESC, cohort_id) = 1,
            base_label,
            CONCAT(base_label, ' (', CAST(ROW_NUMBER() OVER (PARTITION BY base_label ORDER BY cluster_rows DESC, cohort_id) AS STRING), ')')
        ) AS cohort_label
    FROM cluster_base_label
)

SELECT
    predicted.construction_id,
    predicted.cohort_id,
    cluster_label.cohort_label,
    predicted.centroid_distance,
    predicted.second_centroid_distance,
    SAFE_DIVIDE(predicted.centroid_distance, predicted.second_centroid_distance) AS centroid_distance_ratio,
    COALESCE(
        SAFE_DIVIDE(predicted.centroid_distance, predicted.second_centroid_distance) > {{ var('weather_cohort_ambiguity_threshold') }},
        FALSE
    ) AS ambiguous_cohort,
    predicted.precip_type,
    predicted.precip_type_source,
    predicted.precip_intensity,
    predicted.precipitation_inches_capped,
    predicted.visibility_miles_clipped,
    predicted.wind_speed_mph_clipped,
    predicted.humidity_percent,
    predicted.temperature_fahrenheit_clipped,
    predicted.wet_road,
    predicted.freezing_wet,
    predicted.is_freezing,
    predicted.is_precipitating,
    predicted.is_blowing,
    predicted.is_night,
    predicted.impute_source
FROM predicted
LEFT JOIN cluster_label USING (cohort_id)
