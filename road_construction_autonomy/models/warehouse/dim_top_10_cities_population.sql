{{ config(materialized='table') }}

-- population data from Census Bureau estimates for July 1, 2025. 
-- population: https://cdn.www.census.gov/newsroom/press-releases/2026/vintage-2025-city-town-pop-estimates.html
-- land area: https://data.census.gov/
SELECT
    'New York' AS city,
    'NY' AS state,
    8584629 AS population,
    300.5 AS land_area_sq_mi

UNION ALL

SELECT 'Los Angeles', 'CA', 3869089, 469.5
UNION ALL
SELECT 'Chicago', 'IL', 2731585, 227.7
UNION ALL
SELECT 'Houston', 'TX', 2397315, 640.4
UNION ALL
SELECT 'Phoenix', 'AZ', 1665481, 518.0
UNION ALL
SELECT 'San Antonio', 'TX', 1548422, 498.8
UNION ALL
SELECT 'Philadelphia', 'PA', 1574281, 134.4
UNION ALL
SELECT 'San Diego', 'CA', 1406106, 325.9
UNION ALL
SELECT 'Dallas', 'TX', 1329491, 339.6
UNION ALL
SELECT 'Austin', 'TX', 1002632, 319.9