-- self_driving_impact_score must be within 0-10 with at most one decimal
SELECT construction_id, self_driving_impact_score
FROM {{ ref('fact_construction_weather_impact') }}
WHERE self_driving_impact_score NOT BETWEEN 0 AND 10
   OR ROUND(self_driving_impact_score, 1) != self_driving_impact_score
