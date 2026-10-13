{{ config(materialized='table') }}

with staging as (
    select *
    from {{ ref('stg_construction') }}
)

select *
from staging
