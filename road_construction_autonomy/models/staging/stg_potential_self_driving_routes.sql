{{ config(materialized='table') }}


SELECT
    path_name AS path_name,
    SAFE.ST_GEOGFROMTEXT(path_wkt) AS path_geography,
    distance_mi AS distance_mi
FROM  {{ source('road_construction', 'potential_self_driving_routes') }}