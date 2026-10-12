{#
    weather_impact_ctes(source): CTEs that score every row of `source` (a CTE or relation with the
    columns of int_construction_weather_cohorts). Used by fact_construction_weather_impact and by
    analyses/weather_impact_score_breakdown.sql so both compute exactly the same components.

    Structure ("worst hazard wins"):
      visibility_hazard     piecewise-linear in visibility_miles_clipped (seed points, interpolated)
      precip_sensor_hazard  precip_type x precip_intensity (seed)
      traction_hazard       first matching rule (seed values):
                              freezing precipitation at or below var weather_freezing_threshold_f
                              -> snow by intensity
                              -> freezing_wet, or freezing precipitation above the threshold (black ice value)
                              -> heavy rain / heavy thunderstorm (hydroplaning) -> wet road -> dry
      base_score            worst hazard + var weather_impact_second_hazard_bonus x second-worst
      additions             darkness, wind (linear between two speeds), blowing (vars)
      self_driving_impact_score = clip(base + additions, 0, 10), one decimal
    The last CTE is `scored`.
#}

{% macro weather_impact_ctes(source) %}
impact_lookup AS (
    SELECT * FROM {{ ref('weather_impact_hazard_lookup') }}
),

-- visibility points -> half-open segments [x_from, x_to); constant beyond the first and last point
visibility_points AS (
    SELECT visibility_miles AS x, hazard_value AS y
    FROM impact_lookup
    WHERE hazard = 'visibility'
),

visibility_segments AS (
    SELECT
        x AS x_from,
        COALESCE(LEAD(x) OVER (ORDER BY x), CAST('inf' AS FLOAT64)) AS x_to,
        y AS y_from,
        COALESCE(LEAD(y) OVER (ORDER BY x), y) AS y_to
    FROM visibility_points
    UNION ALL
    SELECT
        CAST('-inf' AS FLOAT64) AS x_from,
        MIN(x) AS x_to,
        ARRAY_AGG(y ORDER BY x LIMIT 1)[OFFSET(0)] AS y_from,
        ARRAY_AGG(y ORDER BY x LIMIT 1)[OFFSET(0)] AS y_to
    FROM visibility_points
),

precip_sensor_lookup AS (
    SELECT rule AS precip_type, precip_intensity, hazard_value
    FROM impact_lookup
    WHERE hazard = 'precip_sensor'
),

traction_lookup AS (
    SELECT
        MAX(IF(rule = 'freezing_precip', hazard_value, NULL)) AS freezing_precip,
        MAX(IF(rule = 'snow' AND precip_intensity = 'light', hazard_value, NULL)) AS snow_light,
        MAX(IF(rule = 'snow' AND precip_intensity = 'moderate', hazard_value, NULL)) AS snow_moderate,
        MAX(IF(rule = 'snow' AND precip_intensity = 'heavy', hazard_value, NULL)) AS snow_heavy,
        MAX(IF(rule = 'freezing_wet', hazard_value, NULL)) AS freezing_wet,
        MAX(IF(rule = 'heavy_rain', hazard_value, NULL)) AS heavy_rain,
        MAX(IF(rule = 'wet_road', hazard_value, NULL)) AS wet_road,
        MAX(IF(rule = 'dry', hazard_value, NULL)) AS dry
    FROM impact_lookup
    WHERE hazard = 'traction'
),

impact_hazards AS (
    SELECT
        src.*,
        IF(
            seg.y_from = seg.y_to,
            seg.y_from,
            seg.y_from + (seg.y_to - seg.y_from) * (src.visibility_miles_clipped - seg.x_from) / (seg.x_to - seg.x_from)
        ) AS visibility_hazard,
        COALESCE(ps.hazard_value, 0) AS precip_sensor_hazard,
        CASE
            WHEN src.is_freezing AND COALESCE(src.is_precipitating, FALSE)
                 AND src.temperature_fahrenheit_clipped <= {{ var('weather_freezing_threshold_f') }}
                THEN tl.freezing_precip
            WHEN src.precip_type = 'snow' AND src.precip_intensity = 'heavy' THEN tl.snow_heavy
            WHEN src.precip_type = 'snow' AND src.precip_intensity = 'moderate' THEN tl.snow_moderate
            WHEN src.precip_type = 'snow' AND src.precip_intensity = 'light' THEN tl.snow_light
            -- black ice risk; freezing precipitation above the freezing threshold gets the same value
            WHEN src.freezing_wet OR (src.is_freezing AND COALESCE(src.is_precipitating, FALSE)) THEN tl.freezing_wet
            WHEN src.precip_type IN ('rain', 'thunderstorm') AND src.precip_intensity = 'heavy' THEN tl.heavy_rain
            WHEN src.wet_road THEN tl.wet_road
            ELSE tl.dry
        END AS traction_hazard
    FROM {{ source }} AS src
    INNER JOIN visibility_segments AS seg
        ON src.visibility_miles_clipped >= seg.x_from
        AND src.visibility_miles_clipped < seg.x_to
    LEFT JOIN precip_sensor_lookup AS ps
        ON ps.precip_type = src.precip_type
        AND ps.precip_intensity = src.precip_intensity
    CROSS JOIN traction_lookup AS tl
),

impact_base AS (
    SELECT
        *,
        GREATEST(visibility_hazard, precip_sensor_hazard, traction_hazard) AS worst_hazard,
        visibility_hazard + precip_sensor_hazard + traction_hazard
            - GREATEST(visibility_hazard, precip_sensor_hazard, traction_hazard)
            - LEAST(visibility_hazard, precip_sensor_hazard, traction_hazard) AS second_hazard,
        CASE
            WHEN GREATEST(visibility_hazard, precip_sensor_hazard, traction_hazard) = 0 THEN 'none'
            WHEN visibility_hazard >= GREATEST(precip_sensor_hazard, traction_hazard) THEN 'visibility'
            WHEN precip_sensor_hazard >= traction_hazard THEN 'precip_sensor'
            ELSE 'traction'
        END AS hazard_driver
    FROM impact_hazards
),

impact_additions AS (
    SELECT
        *,
        worst_hazard + {{ var('weather_impact_second_hazard_bonus') }} * second_hazard AS base_score,
        IF(is_night, {{ var('weather_impact_darkness_add') }}, 0) AS darkness_add,
        {{ var('weather_impact_wind_max_add') }} * LEAST(GREATEST(
            (wind_speed_mph_clipped - {{ var('weather_impact_wind_start_mph') }})
            / ({{ var('weather_impact_wind_full_mph') }} - {{ var('weather_impact_wind_start_mph') }}),
            0), 1) AS wind_add,
        IF(is_blowing, {{ var('weather_impact_blowing_add') }}, 0) AS blowing_add
    FROM impact_base
),

scored AS (
    SELECT
        *,
        ROUND(LEAST(GREATEST(base_score + darkness_add + wind_add + blowing_add, 0), 10), 1) AS self_driving_impact_score
    FROM impact_additions
)
{% endmacro %}


{% macro weather_impact_level(score_column) %}
    CASE
        WHEN {{ score_column }} >= {{ var('weather_impact_level_severe_min') }} THEN 'Severe'
        WHEN {{ score_column }} >= {{ var('weather_impact_level_high_min') }} THEN 'High'
        WHEN {{ score_column }} >= {{ var('weather_impact_level_moderate_min') }} THEN 'Moderate'
        ELSE 'Low'
    END
{% endmacro %}
