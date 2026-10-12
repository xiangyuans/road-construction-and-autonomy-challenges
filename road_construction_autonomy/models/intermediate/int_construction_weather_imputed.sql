{{ config(materialized='table') }}

{#-
    Fills missing weather fields for every construction event without dropping rows.
    Order: impossible values -> null (precipitation, wind, temperature, visibility; each flagged
    in <field>_invalid), then weather_condition (levels 1-4, mode), then the numeric fields
    (levels 1-6, exact median; wind is zero-filled first when wind_direction reports calm),
    then precipitation (zero-fill when the condition is non-precipitating, otherwise levels 1-6).
    Neighbor statistics use measured values only (zero-filled values are not neighbors).
-#}

{%- set min_n = var('weather_imputation_min_match_count') -%}
{%- set invalid_in = var('weather_precip_invalid_threshold_in') -%}
{%- set wind_max = var('weather_wind_invalid_max_mph') -%}
{%- set temp_min = var('weather_temperature_invalid_min_f') -%}
{%- set temp_max = var('weather_temperature_invalid_max_f') -%}
{%- set vis_min = var('weather_visibility_invalid_min_mi') -%}
{%- set vis_max = var('weather_visibility_invalid_max_mi') -%}
{%- set heavy_min = var('weather_precip_heavy_min_in') -%}
{%- set zero_vis_types = var('weather_visibility_zero_valid_precip_types') -%}
{%- set numeric_fields = [
    'temperature_fahrenheit',
    'humidity_percent',
    'visibility_miles',
    'wind_speed_mph',
    'precipitation_inches',
] -%}

WITH fact AS (
    SELECT
        construction_id,
        postal_code,
        state,
        city,
        weather_observation_time,
        start_time_local,
        weather_condition,
        temperature_fahrenheit,
        humidity_percent,
        visibility_miles,
        wind_speed_mph,
        wind_direction,
        precipitation_inches
    FROM {{ ref('fact_construction') }}
),

seed AS (
    SELECT weather_condition, precip_type, precip_intensity, is_precipitating
    FROM {{ ref('weather_condition_mapping') }}
),

-- visibility = 0 is only plausible in fog, snow, freezing precipitation or heavy precipitation
-- (judged from the measured condition text and precipitation, before any imputation)
fact_checked AS (
    SELECT
        fact.*,
        (
            COALESCE(measured.precip_type IN ({% for t in zero_vis_types %}'{{ t }}'{{ ', ' if not loop.last }}{% endfor %}), FALSE)
            OR COALESCE(measured.precip_intensity = 'heavy', FALSE)
            OR COALESCE(fact.precipitation_inches > {{ heavy_min }} AND fact.precipitation_inches < {{ invalid_in }}, FALSE)
        ) AS zero_visibility_plausible
    FROM fact
    LEFT JOIN seed AS measured
        ON measured.weather_condition = REGEXP_REPLACE(LOWER(TRIM(fact.weather_condition)), r'\s+', ' ')
),

base AS (
    SELECT
        construction_id,
        postal_code,
        state,
        city,
        COALESCE(weather_observation_time, start_time_local) AS weather_timestamp,
        IF(weather_observation_time IS NULL, 'start_time_local', 'weather_observation_time') AS weather_timestamp_source,
        TIMESTAMP_TRUNC(COALESCE(weather_observation_time, start_time_local), HOUR) AS weather_hour,
        DATE(COALESCE(weather_observation_time, start_time_local)) AS weather_date,
        DATE_TRUNC(DATE(COALESCE(weather_observation_time, start_time_local)), MONTH) AS weather_month,
        1 AS all_rows,
        -- same normalization as seeds/weather_condition_mapping.csv
        REGEXP_REPLACE(LOWER(TRIM(weather_condition)), r'\s+', ' ') AS weather_condition,
        -- impossible readings are sensor errors: null them before imputation and flag them
        COALESCE(temperature_fahrenheit < {{ temp_min }} OR temperature_fahrenheit > {{ temp_max }}, FALSE) AS temperature_invalid,
        IF(temperature_fahrenheit < {{ temp_min }} OR temperature_fahrenheit > {{ temp_max }}, NULL, temperature_fahrenheit) AS temperature_fahrenheit,
        humidity_percent,
        COALESCE(
            visibility_miles < {{ vis_min }} OR visibility_miles > {{ vis_max }}
            OR (visibility_miles = 0 AND NOT zero_visibility_plausible),
            FALSE
        ) AS visibility_invalid,
        IF(
            visibility_miles < {{ vis_min }} OR visibility_miles > {{ vis_max }}
            OR (visibility_miles = 0 AND NOT zero_visibility_plausible),
            NULL, visibility_miles
        ) AS visibility_miles,
        COALESCE(wind_speed_mph > {{ wind_max }}, FALSE) AS wind_speed_invalid,
        IF(wind_speed_mph > {{ wind_max }}, NULL, wind_speed_mph) AS wind_speed_mph,
        -- older feed records calm as wind_direction 'Calm' with a null speed
        COALESCE(LOWER(TRIM(wind_direction)) = 'calm', FALSE) AS wind_is_calm,
        precipitation_inches AS precipitation_inches_raw,
        COALESCE(precipitation_inches >= {{ invalid_in }}, FALSE) AS precip_invalid,
        IF(precipitation_inches >= {{ invalid_in }}, NULL, precipitation_inches) AS precipitation_inches
    FROM fact_checked
),

-- each measured row also counts toward the neighboring hour buckets (±1 hour levels)
base_hourly AS (
    SELECT
        base.*,
        TIMESTAMP_ADD(base.weather_hour, INTERVAL hour_offset HOUR) AS neighbor_hour
    FROM base
    CROSS JOIN UNNEST([-1, 0, 1]) AS hour_offset
),

-- ---------------------------------------------------------------- weather_condition: mode, levels 1-4

condition_l1 AS (
    {{ group_mode('(SELECT postal_code, neighbor_hour, weather_condition FROM base_hourly WHERE postal_code IS NOT NULL)',
                  ['postal_code', 'neighbor_hour'], 'weather_condition') }}
),

condition_l2 AS (
    {{ group_mode('(SELECT state, city, neighbor_hour, weather_condition FROM base_hourly WHERE city IS NOT NULL)',
                  ['state', 'city', 'neighbor_hour'], 'weather_condition') }}
),

condition_l3 AS (
    {{ group_mode('(SELECT state, city, weather_date, weather_condition FROM base WHERE city IS NOT NULL)',
                  ['state', 'city', 'weather_date'], 'weather_condition') }}
),

condition_l4 AS (
    {{ group_mode('(SELECT state, city, weather_month, weather_condition FROM base WHERE city IS NOT NULL)',
                  ['state', 'city', 'weather_month'], 'weather_condition') }}
),

condition_imputed AS (
    SELECT
        base.*,
        CASE
            WHEN base.weather_condition IS NOT NULL THEN base.weather_condition
            WHEN c1.total_count >= {{ min_n }} THEN c1.mode_value
            WHEN c2.total_count >= {{ min_n }} THEN c2.mode_value
            WHEN c3.total_count >= {{ min_n }} THEN c3.mode_value
            WHEN c4.total_count >= {{ min_n }} THEN c4.mode_value
        END AS weather_condition_imputed,
        CASE
            WHEN base.weather_condition IS NOT NULL THEN 0
            WHEN c1.total_count >= {{ min_n }} THEN 1
            WHEN c2.total_count >= {{ min_n }} THEN 2
            WHEN c3.total_count >= {{ min_n }} THEN 3
            WHEN c4.total_count >= {{ min_n }} THEN 4
        END AS weather_condition_level
    FROM base
    LEFT JOIN condition_l1 AS c1
        ON c1.postal_code = base.postal_code AND c1.neighbor_hour = base.weather_hour
    LEFT JOIN condition_l2 AS c2
        ON c2.state = base.state AND c2.city = base.city AND c2.neighbor_hour = base.weather_hour
    LEFT JOIN condition_l3 AS c3
        ON c3.state = base.state AND c3.city = base.city AND c3.weather_date = base.weather_date
    LEFT JOIN condition_l4 AS c4
        ON c4.state = base.state AND c4.city = base.city AND c4.weather_month = base.weather_month
),

-- ---------------------------------------------------------------- numeric fields: exact median, levels 1-6

numeric_l1 AS (
    {{ exact_group_medians('(SELECT postal_code, neighbor_hour, ' ~ numeric_fields | join(', ') ~ ' FROM base_hourly WHERE postal_code IS NOT NULL)',
                           ['postal_code', 'neighbor_hour'], numeric_fields) }}
),

numeric_l2 AS (
    {{ exact_group_medians('(SELECT state, city, neighbor_hour, ' ~ numeric_fields | join(', ') ~ ' FROM base_hourly WHERE city IS NOT NULL)',
                           ['state', 'city', 'neighbor_hour'], numeric_fields) }}
),

numeric_l3 AS (
    {{ exact_group_medians('(SELECT state, city, weather_date, ' ~ numeric_fields | join(', ') ~ ' FROM base WHERE city IS NOT NULL)',
                           ['state', 'city', 'weather_date'], numeric_fields) }}
),

numeric_l4 AS (
    {{ exact_group_medians('(SELECT state, city, weather_month, ' ~ numeric_fields | join(', ') ~ ' FROM base WHERE city IS NOT NULL)',
                           ['state', 'city', 'weather_month'], numeric_fields) }}
),

-- grouped by the imputed condition; rows whose condition is still null skip this level
numeric_l5 AS (
    {{ exact_group_medians('(SELECT weather_condition_imputed, weather_month, ' ~ numeric_fields | join(', ') ~ ' FROM condition_imputed WHERE weather_condition_imputed IS NOT NULL)',
                           ['weather_condition_imputed', 'weather_month'], numeric_fields) }}
),

numeric_l6 AS (
    {{ exact_group_medians('(SELECT all_rows, ' ~ numeric_fields | join(', ') ~ ' FROM base)',
                           ['all_rows'], numeric_fields) }}
),

numeric_imputed AS (
    SELECT
        c.*,
        {%- for f in numeric_fields %}
        -- {{ f }}: level 0 = measured, -1 = zero-filled (precipitation, wind), NULL = still missing
        CASE
            WHEN c.{{ f }} IS NOT NULL THEN 0
            {%- if f == 'precipitation_inches' %}
            WHEN seed.is_precipitating = FALSE THEN -1
            {%- elif f == 'wind_speed_mph' %}
            WHEN c.wind_is_calm THEN -1
            {%- endif %}
            {%- for lvl in range(1, 7) %}
            WHEN n{{ lvl }}.n_{{ f }} >= {{ min_n }} THEN {{ lvl }}
            {%- endfor %}
        END AS {{ f }}_level,
        CASE
            WHEN c.{{ f }} IS NOT NULL THEN c.{{ f }}
            {%- if f == 'precipitation_inches' %}
            WHEN seed.is_precipitating = FALSE THEN 0
            {%- elif f == 'wind_speed_mph' %}
            WHEN c.wind_is_calm THEN 0
            {%- endif %}
            {%- for lvl in range(1, 7) %}
            WHEN n{{ lvl }}.n_{{ f }} >= {{ min_n }} THEN n{{ lvl }}.median_{{ f }}
            {%- endfor %}
        END AS {{ f }}_imputed{{ ',' if not loop.last }}
        {%- endfor %}
    FROM condition_imputed AS c
    LEFT JOIN seed
        ON seed.weather_condition = c.weather_condition_imputed
    LEFT JOIN numeric_l1 AS n1
        ON n1.postal_code = c.postal_code AND n1.neighbor_hour = c.weather_hour
    LEFT JOIN numeric_l2 AS n2
        ON n2.state = c.state AND n2.city = c.city AND n2.neighbor_hour = c.weather_hour
    LEFT JOIN numeric_l3 AS n3
        ON n3.state = c.state AND n3.city = c.city AND n3.weather_date = c.weather_date
    LEFT JOIN numeric_l4 AS n4
        ON n4.state = c.state AND n4.city = c.city AND n4.weather_month = c.weather_month
    LEFT JOIN numeric_l5 AS n5
        ON n5.weather_condition_imputed = c.weather_condition_imputed AND n5.weather_month = c.weather_month
    LEFT JOIN numeric_l6 AS n6
        ON n6.all_rows = c.all_rows
),

{%- set level_columns = ['weather_condition_level'] -%}
{%- for f in numeric_fields %}{% do level_columns.append(f ~ '_level') %}{% endfor -%}

ranked AS (
    SELECT
        *,
        -- confidence rank per field: measured 0, zero-fill 0.5, level n = n
        GREATEST(
            {%- for col in level_columns %}
            COALESCE(IF({{ col }} = -1, 0.5, {{ col }}), 0){{ ',' if not loop.last }}
            {%- endfor %}
        ) AS max_level_rank,
        {%- for col in level_columns %}
        IF(COALESCE({{ col }}, 0) != 0, 1, 0){{ ' +' if not loop.last }}
        {%- endfor %} AS imputed_fields
    FROM numeric_imputed
)

SELECT
    construction_id,
    postal_code,
    state,
    city,
    weather_timestamp,
    weather_timestamp_source,
    weather_condition_imputed AS weather_condition,
    temperature_fahrenheit_imputed AS temperature_fahrenheit,
    humidity_percent_imputed AS humidity_percent,
    visibility_miles_imputed AS visibility_miles,
    wind_speed_mph_imputed AS wind_speed_mph,
    temperature_invalid,
    visibility_invalid,
    wind_speed_invalid,
    precipitation_inches_raw,
    precip_invalid,
    precipitation_inches_imputed AS precipitation_inches,
    LEAST(precipitation_inches_imputed, {{ var('weather_precip_cap_in') }}) AS precipitation_inches_capped,
    {%- for col in level_columns %}
    CASE {{ col }}
        WHEN 0 THEN 'measured'
        WHEN -1 THEN 'zero_fill'
        ELSE CONCAT('level_', CAST({{ col }} AS STRING))
    END AS {{ col | replace('_level', '_impute_level') }},
    {%- endfor %}
    CASE
        WHEN max_level_rank = 0 THEN 'none'
        WHEN max_level_rank = 0.5 THEN 'zero_fill'
        ELSE CONCAT('level_', CAST(CAST(max_level_rank AS INT64) AS STRING))
    END AS impute_source,
    imputed_fields
FROM ranked
