{{ config(materialized='table') }}

WITH source AS (
    SELECT * FROM {{ source('road_construction', 'us_constructions') }}
),

-- most common non-null city for each zipcode, used to fill missing cities
zipcode_city_counts AS (
    SELECT
        Zipcode AS lookup_zipcode,
        City AS lookup_city,
        COUNT(*) AS city_count
    FROM source
    WHERE Zipcode IS NOT NULL
      AND City IS NOT NULL
    GROUP BY Zipcode, City
),

zipcode_city_ranked AS (
    SELECT
        lookup_zipcode,
        lookup_city,
        ROW_NUMBER() OVER (
            PARTITION BY lookup_zipcode
            ORDER BY city_count DESC, lookup_city
        ) AS city_rank
    FROM zipcode_city_counts
),

zipcode_city AS (
    SELECT
        lookup_zipcode,
        lookup_city
    FROM zipcode_city_ranked
    WHERE city_rank = 1
)

SELECT
    ID AS construction_id,
    Severity AS severity,
    Start_Time AS start_time_local,
    End_Time AS end_time_local,
    Start_Lat AS start_latitude,
    Start_Lng AS start_longitude,
    End_Lat AS end_latitude,
    End_Lng AS end_longitude,
    Distance_mi_ AS distance_mi,
    Description AS description,
    Number AS street_number,
    Street AS street_name,
    Side AS side_of_road,
    COALESCE(s.City, zc.lookup_city) AS city,
    County AS county,
    State AS state,
    LEFT(Zipcode, 5) AS postal_code,
    Country AS country,
    Timezone AS timezone,
    Airport_Code AS airport_code,
    Weather_Timestamp AS weather_observation_time,
    Temperature_F_ AS temperature_fahrenheit,
    Wind_Chill_F_ AS wind_chill_fahrenheit,
    `Humidity_%_` AS humidity_percent,
    Pressure_in_ AS pressure_inches_mercury,
    Visibility_mi_ AS visibility_miles,
    Wind_Direction AS wind_direction,
    Wind_Speed_mph_ AS wind_speed_mph,
    Precipitation_in_ AS precipitation_inches,
    Weather_Condition AS weather_condition,
    Amenity AS has_amenity,
    Bump AS has_bump,
    Crossing AS has_crossing,
    Give_Way AS has_give_way,
    Junction AS has_junction,
    No_Exit AS has_no_exit,
    Railway AS has_railway,
    Roundabout AS has_roundabout,
    Station AS has_station,
    Stop AS has_stop,
    Traffic_Calming AS has_traffic_calming,
    Traffic_Signal AS has_traffic_signal,
    Turning_Loop AS has_turning_loop,
    Sunrise_Sunset AS sunrise_sunset_period,
    Civil_Twilight AS civil_twilight_period,
    Nautical_Twilight AS nautical_twilight_period,
    Astronomical_Twilight AS astronomical_twilight_period
FROM source AS s
LEFT JOIN zipcode_city AS zc
    ON s.Zipcode = zc.lookup_zipcode
