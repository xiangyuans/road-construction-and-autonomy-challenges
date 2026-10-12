-- valid measured values (including precipitation 0.0) must never be overwritten;
-- impossible readings are excluded because they are nulled and imputed by design
SELECT i.construction_id
FROM {{ ref('int_construction_weather_imputed') }} AS i
INNER JOIN {{ ref('fact_construction') }} AS f USING (construction_id)
WHERE (NOT i.temperature_invalid AND f.temperature_fahrenheit IS NOT NULL AND i.temperature_fahrenheit != f.temperature_fahrenheit)
   OR (f.humidity_percent IS NOT NULL AND i.humidity_percent != f.humidity_percent)
   OR (NOT i.visibility_invalid AND f.visibility_miles IS NOT NULL AND i.visibility_miles != f.visibility_miles)
   OR (NOT i.wind_speed_invalid AND f.wind_speed_mph IS NOT NULL AND i.wind_speed_mph != f.wind_speed_mph)
   OR (NOT i.precip_invalid AND f.precipitation_inches IS NOT NULL AND i.precipitation_inches != f.precipitation_inches)
