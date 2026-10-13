{{ config(
    materialized='incremental',
    unique_key='construction_id',
    incremental_strategy='merge',
    on_schema_change='fail'
) }}

{#-
    Weather-only self-driving impact score per construction event (first step of the larger risk analysis).
    Incremental: each run recomputes scores from the upstream tables (cheap) and merges only rows that are
    new or whose score, level, cohort or impute_source changed; --full-refresh rewrites everything.
    Severity is intentionally not used (it describes the construction, not the weather).
-#}

WITH cohorts AS (
    SELECT *
    FROM {{ ref('int_construction_weather_cohorts') }}
),

{{ weather_impact_ctes('cohorts') }},

final AS (
    SELECT
        construction_id,
        self_driving_impact_score,
        {{ weather_impact_level('self_driving_impact_score') }} AS self_driving_impact_level,
        -- the model was trained without unknown-type rows, so their nearest cohort isn't meaningful as a label
        IF(precip_type = 'unknown', 'Unknown', cohort_label) AS cohort_label,
        impute_source
    FROM scored
)

SELECT final.*
FROM final
{% if is_incremental() %}
LEFT JOIN {{ this }} AS existing
    ON existing.construction_id = final.construction_id
WHERE existing.construction_id IS NULL
   OR existing.self_driving_impact_score != final.self_driving_impact_score
   OR existing.self_driving_impact_level != final.self_driving_impact_level
   OR existing.cohort_label IS DISTINCT FROM final.cohort_label
   OR existing.impute_source != final.impute_source
{% endif %}
