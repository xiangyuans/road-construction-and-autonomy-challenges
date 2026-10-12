{{ config(materialized='table') }}

with staging as (
    select *
    from {{ ref('stg_potential_self_driving_routes') }}
)

select *
from staging
