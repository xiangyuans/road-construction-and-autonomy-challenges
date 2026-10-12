{{ config(materialized='table') }}

{#-
    Deterministic stratified training sample for the weather cohort k-means model, shared by
    BigQuery ML (int_construction_weather_cohorts) and the exploration notebook.
    Strata: month-of-year x precip_type, unknown precip_type excluded. Each stratum gets its proportional
    share of the target rows but at least the minimum (or all its rows), so rare conditions are kept.
    Rows are chosen by FARM_FINGERPRINT(construction_id:random_state), so the sample is identical on every run.
-#}

WITH features AS (
    SELECT
        *,
        EXTRACT(MONTH FROM weather_timestamp) AS weather_month_of_year
    FROM {{ ref('int_construction_weather_features') }}
    WHERE precip_type != 'unknown'
),

strata AS (
    SELECT weather_month_of_year, precip_type, COUNT(*) AS stratum_rows
    FROM features
    GROUP BY 1, 2
),

allocation AS (
    SELECT
        *,
        LEAST(
            stratum_rows,
            GREATEST(
                CAST(ROUND({{ var('weather_cohort_sample_target_rows') }} * stratum_rows / SUM(stratum_rows) OVER ()) AS INT64),
                {{ var('weather_cohort_sample_min_per_stratum') }}
            )
        ) AS stratum_quota
    FROM strata
),

ranked AS (
    SELECT
        features.*,
        allocation.stratum_rows,
        allocation.stratum_quota,
        ROW_NUMBER() OVER (
            PARTITION BY features.weather_month_of_year, features.precip_type
            ORDER BY FARM_FINGERPRINT(CONCAT(features.construction_id, ':', '{{ var('weather_cohort_random_state') }}'))
        ) AS stratum_rank
    FROM features
    INNER JOIN allocation USING (weather_month_of_year, precip_type)
),

init_centroids AS (
    SELECT construction_id
    FROM {{ ref('weather_cohort_init_centroids') }}
)

SELECT
    ranked.* EXCEPT (stratum_rank),
    ranked.stratum_rows / ranked.stratum_quota AS sample_weight,
    init_centroids.construction_id IS NOT NULL AS is_init_centroid,
    {{ weather_cohort_feature_columns() }}
FROM ranked
LEFT JOIN init_centroids USING (construction_id)
WHERE ranked.stratum_rank <= ranked.stratum_quota
