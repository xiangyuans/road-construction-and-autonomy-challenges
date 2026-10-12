-- clipped columns must stay inside their var limits
SELECT construction_id
FROM {{ ref('int_construction_weather_features') }}
WHERE temperature_fahrenheit_clipped NOT BETWEEN {{ var('weather_temperature_clip_min_f') }} AND {{ var('weather_temperature_clip_max_f') }}
   OR visibility_miles_clipped NOT BETWEEN {{ var('weather_visibility_clip_min_mi') }} AND {{ var('weather_visibility_clip_max_mi') }}
   OR wind_speed_mph_clipped NOT BETWEEN {{ var('weather_wind_clip_min_mph') }} AND {{ var('weather_wind_clip_max_mph') }}
