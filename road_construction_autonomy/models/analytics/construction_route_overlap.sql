{{ config(materialized='table') }}

{% set zone_half_width_m = 10 %}   -- half the width of the construction area (~1 lane each side)

with construction as (

    select
        construction_id,
        city,
        state,
        postal_code,
        st_geogpoint(start_longitude, start_latitude) as start_pt,
        -- ~10% of rows have no end coordinates: treat them as point-like constructions
        st_geogpoint(coalesce(end_longitude, start_longitude), coalesce(end_latitude, start_latitude)) as end_pt
    from {{ ref('fact_construction') }}

),

construction_zone as (

    select
        *,
        case
            -- start = end: a point-like construction, use a round area
            when st_distance(start_pt, end_pt) < 1
                then st_buffer(start_pt, {{ zone_half_width_m }})
            else st_buffer(st_makeline(start_pt, end_pt), {{ zone_half_width_m }}, endcap => 'FLAT')
        end as zone_geog
    from construction

),

routes as (

    select path_name, path_geography
    from {{ ref('dim_potential_self_driving_routes') }}

),

-- Any route that touches the construction area
matches as (

    select
        z.construction_id,
        r.path_name,
        st_length(st_intersection(r.path_geography, z.zone_geog))                 as overlapped_distance_m,
        -- middle of the overlapped section, snapped onto the route (for maps)
        st_closestpoint(r.path_geography, st_centroid(st_intersection(r.path_geography, z.zone_geog)))
                                                                                  as overlap_spot,
        st_dwithin(z.start_pt, r.path_geography, {{ zone_half_width_m }})         as start_on_path,
        st_dwithin(z.end_pt,   r.path_geography, {{ zone_half_width_m }})         as end_on_path
    from construction_zone z
    join routes r
      on st_intersects(z.zone_geog, r.path_geography)

)

select
    c.construction_id,
    m.path_name is not null                as is_overlapped,
    case
        when m.path_name is null                                        then 'none'
        when m.start_on_path and m.end_on_path                          then 'full'      -- route runs the whole length
        when m.overlapped_distance_m <= 2 * {{ zone_half_width_m }}     then 'crossing'  -- route cuts across
        else                                                                 'partial'   -- route runs along part of it
    end                                    as overlap_type,
    c.city,
    c.state,
    c.postal_code,
    m.path_name,
    coalesce(m.overlapped_distance_m, 0)   as overlapped_distance_m,
    coalesce(m.start_on_path, false)       as start_on_path,
    coalesce(m.end_on_path, false)         as end_on_path,
    m.overlap_spot
from construction c
left join matches m
  using (construction_id)
