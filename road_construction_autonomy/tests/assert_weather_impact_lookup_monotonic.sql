-- every hazard lookup table must be monotonic (worse conditions never score lower)
WITH hazard_lookup AS (
    SELECT * FROM {{ ref('weather_impact_hazard_lookup') }}
),
visibility AS (
    SELECT 'visibility falls as visibility rises' AS failure, visibility_miles, hazard_value,
           LEAD(hazard_value) OVER (ORDER BY visibility_miles) AS next_value
    FROM hazard_lookup WHERE hazard = 'visibility'
),
intensity AS (
    SELECT hazard, rule,
           MAX(IF(precip_intensity = 'light', hazard_value, NULL)) AS light,
           MAX(IF(precip_intensity = 'moderate', hazard_value, NULL)) AS moderate,
           MAX(IF(precip_intensity = 'heavy', hazard_value, NULL)) AS heavy
    FROM hazard_lookup WHERE precip_intensity IS NOT NULL
    GROUP BY hazard, rule
),
traction AS (
    SELECT
        MAX(IF(rule = 'dry', hazard_value, NULL)) AS dry,
        MAX(IF(rule = 'wet_road', hazard_value, NULL)) AS wet_road,
        MAX(IF(rule = 'heavy_rain', hazard_value, NULL)) AS heavy_rain,
        MAX(IF(rule = 'freezing_wet', hazard_value, NULL)) AS freezing_wet,
        MAX(IF(rule = 'snow' AND precip_intensity = 'light', hazard_value, NULL)) AS snow_light,
        MAX(IF(rule = 'snow' AND precip_intensity = 'heavy', hazard_value, NULL)) AS snow_heavy,
        MAX(IF(rule = 'freezing_precip', hazard_value, NULL)) AS freezing_precip
    FROM hazard_lookup WHERE hazard = 'traction'
)
SELECT failure FROM visibility WHERE next_value > hazard_value
UNION ALL
SELECT CONCAT(hazard, '/', rule, ' must rise with intensity') FROM intensity WHERE NOT (light <= moderate AND moderate <= heavy)
UNION ALL
SELECT 'snow sensor hazard below rain' FROM intensity AS snow JOIN intensity AS rain
    ON snow.hazard = 'precip_sensor' AND snow.rule = 'snow' AND rain.hazard = 'precip_sensor' AND rain.rule = 'rain'
WHERE snow.light < rain.light OR snow.moderate < rain.moderate OR snow.heavy < rain.heavy
UNION ALL
SELECT 'traction chain not monotonic' FROM traction
WHERE NOT (dry <= wet_road AND wet_road <= heavy_rain AND heavy_rain <= freezing_wet AND freezing_wet <= snow_light
           AND snow_light <= snow_heavy AND snow_heavy <= freezing_precip)
UNION ALL
SELECT 'hazard value outside 0-10' FROM hazard_lookup WHERE hazard_value NOT BETWEEN 0 AND 10
