{#
    Weather cohort clustering (BigQuery ML k-means).

    weather_cohort_feature_names / weather_cohort_feature_columns: the 17 clustering features, encoded
    exactly like build_features() in notebooks/weather_cohort_exploration.ipynb (section 3). Columns are
    prefixed feat_ so they never collide with pass-through columns in ML.PREDICT. BigQuery ML standardizes
    them (standardize_features = TRUE), like the notebook's StandardScaler.

    weather_cohort_model_relation: where the saved model lives (the intermediate dataset).

    train_weather_cohort_model: pre-hook for int_construction_weather_cohorts. With var
    refit_cohort_model = true it retrains (CREATE OR REPLACE MODEL); otherwise CREATE MODEL IF NOT EXISTS,
    which only trains when no saved model exists yet and is a no-op on every other run.
#}

{% macro weather_cohort_precip_types() %}
    {{ return(['clear_cloudy', 'rain', 'snow', 'ice_freezing', 'fog', 'haze_smoke_dust', 'thunderstorm']) }}
{% endmacro %}


{% macro weather_cohort_feature_names() %}
    {%- set names = ['feat_precipitation_inches_capped', 'feat_visibility_miles_clipped', 'feat_wind_speed_mph_clipped',
                     'feat_humidity_percent', 'feat_temperature_fahrenheit_clipped'] -%}
    {%- for t in weather_cohort_precip_types() %}{% do names.append('feat_type_' ~ t) %}{% endfor -%}
    {%- do names.extend(['feat_precip_intensity_ord', 'feat_wet_road', 'feat_freezing_wet', 'feat_is_blowing', 'feat_is_night']) -%}
    {{ return(names) }}
{% endmacro %}


{% macro weather_cohort_feature_columns() %}
    CAST(precipitation_inches_capped AS FLOAT64) AS feat_precipitation_inches_capped,
    CAST(visibility_miles_clipped AS FLOAT64) AS feat_visibility_miles_clipped,
    CAST(wind_speed_mph_clipped AS FLOAT64) AS feat_wind_speed_mph_clipped,
    CAST(humidity_percent AS FLOAT64) AS feat_humidity_percent,
    CAST(temperature_fahrenheit_clipped AS FLOAT64) AS feat_temperature_fahrenheit_clipped,
    {%- for t in weather_cohort_precip_types() %}
    IF(precip_type = '{{ t }}', 1.0, 0.0) AS feat_type_{{ t }},
    {%- endfor %}
    CASE precip_intensity WHEN 'light' THEN 1.0 WHEN 'moderate' THEN 2.0 WHEN 'heavy' THEN 3.0 ELSE 0.0 END AS feat_precip_intensity_ord,
    IF(wet_road, 1.0, 0.0) AS feat_wet_road,
    IF(freezing_wet, 1.0, 0.0) AS feat_freezing_wet,
    IF(is_blowing, 1.0, 0.0) AS feat_is_blowing,
    IF(is_night, 1.0, 0.0) AS feat_is_night
{% endmacro %}


{% macro weather_cohort_model_relation() %}
    {{ return('`' ~ this.database ~ '.' ~ this.schema ~ '.weather_cohort_kmeans`') }}
{% endmacro %}


{% macro train_weather_cohort_model() %}
    {%- set refit = var('refit_cohort_model') | string | lower in ['true', '1', 'yes'] -%}
    {%- set has_init = execute and (run_query('SELECT COUNT(*) FROM ' ~ ref('weather_cohort_init_centroids')).columns[0].values()[0] | int) == var('weather_cohort_k') -%}
    CREATE {{ 'OR REPLACE MODEL' if refit else 'MODEL IF NOT EXISTS' }} {{ weather_cohort_model_relation() }}
    OPTIONS (
        model_type = 'KMEANS',
        num_clusters = {{ var('weather_cohort_k') }},
        standardize_features = TRUE,
        distance_type = 'EUCLIDEAN',
        {%- if has_init %}
        kmeans_init_method = 'CUSTOM',
        kmeans_init_col = 'is_init_centroid',
        {%- else %}
        kmeans_init_method = 'KMEANS++',
        {%- endif %}
        max_iterations = 50,
        early_stop = TRUE,
        min_rel_progress = 0.0001
    ) AS
    SELECT
        {{ weather_cohort_feature_names() | join(',\n        ') }}
        {%- if has_init %},
        is_init_centroid
        {%- endif %}
    FROM {{ ref('int_weather_cohort_training_sample') }}
{% endmacro %}
