{{ config(materialized='table') }}

{% set min_overlap_m = 50 %}   -- weak match: not fully on the route and less than this much on it
{% set high_severity_levels = [3, 4] %}   -- severity 1 (short delay) to 4 (long delay); 3 and 4 are high

-- One row per potential self-driving route: construction on the route, 2017-2021.
-- A construction that touches two routes (e.g. the shared Bay Bridge trunk) counts on both.
-- Hours are the full duration of each overlapping construction, not prorated by overlapped length.
-- Weak matches are dropped: a construction that only crosses the route, or only starts or ends at it
-- (not fully on the route and < min_overlap_m overlapped), mostly lies on another road.
WITH route_construction AS (
    SELECT
        o.path_name,
        fc.construction_id,
        fc.severity,
        wi.self_driving_impact_level,
        TIMESTAMP_DIFF(fc.end_time_local, fc.start_time_local, SECOND) / 3600.0 AS construction_hours,
        o.overlap_spot AS construction_spot
    FROM {{ ref('construction_route_overlap') }} AS o
    INNER JOIN {{ ref('fact_construction') }} AS fc
        ON o.construction_id = fc.construction_id
    LEFT JOIN {{ ref('fact_construction_weather_impact') }} AS wi
        ON o.construction_id = wi.construction_id
    WHERE o.is_overlapped
        AND (o.overlap_type = 'full' OR o.overlapped_distance_m >= {{ min_overlap_m }})
        AND DATE(fc.start_time_local) >= DATE('2017-01-01')
        AND DATE(fc.start_time_local) < DATE('2022-01-01')
),

-- GEOGRAPHY can't be grouped on, so aggregate first and join the route shape after
route_metrics AS (
    SELECT
        path_name,
        COUNT(construction_id) AS construction_count,
        ROUND(SUM(construction_hours), 2) AS construction_hours,
        ROUND(SUM(IF(severity IN ({{ high_severity_levels | join(', ') }}), construction_hours, 0)), 2)
            AS high_severity_hours,
        ROUND(SUM(IF(self_driving_impact_level IN ('High', 'Severe'), construction_hours, 0)), 2)
            AS high_severe_impact_hours,
        ST_UNION_AGG(construction_spot) AS construction_spots -- where each construction meets the route, for maps
    FROM route_construction
    GROUP BY path_name
)

SELECT
    r.path_name,
    r.distance_mi,
    COALESCE(m.construction_count, 0) AS construction_count,
    COALESCE(m.construction_hours, 0) AS construction_hours,
    COALESCE(m.high_severity_hours, 0) AS high_severity_hours,
    COALESCE(m.high_severe_impact_hours, 0) AS high_severe_impact_hours,
    ROUND(SAFE_DIVIDE(m.construction_hours, r.distance_mi), 2) AS construction_hours_per_mi,
    r.path_geography,
    m.construction_spots
FROM {{ ref('dim_potential_self_driving_routes') }} AS r
LEFT JOIN route_metrics AS m
    ON r.path_name = m.path_name
