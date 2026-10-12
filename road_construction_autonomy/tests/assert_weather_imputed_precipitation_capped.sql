-- precipitation_inches_capped must never exceed the cap var
SELECT construction_id, precipitation_inches_capped
FROM {{ ref('int_construction_weather_imputed') }}
WHERE precipitation_inches_capped > {{ var('weather_precip_cap_in') }}
