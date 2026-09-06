# Data schema

All layers are GeoJSON FeatureCollections. Coordinates are `[lon, lat]`, WGS84. Every feature has `id`, `name`, `notes`, and `needs_tracing`. Extra fields are allowed; the map shows whatever is there.

## mowing_areas.geojson (Polygons)

| field | type | meaning |
|---|---|---|
| id | string | `MOW-##`, stable |
| name | string | what the crew calls it |
| category | string | one of the mowing map legend categories: UND Green Space, Sports Fields, REA, EERC, Foundation, Greenway, Golf Course, Primary Housing, Housing, Alumni, Wellness. Drives the color. |
| acres | number | from the UND mowing map, number of record |
| crew | string | crew or person assigned, empty if unknown |
| frequency | string | weekly, 2x weekly, biweekly, course schedule, as needed |
| mower | string | preferred unit, matches a name in assets |
| needs_tracing | boolean | true until redrawn on imagery |
| notes | string | anything else |

## snow_routes.geojson (LineStrings for routes, Polygons for zones and lots)

| field | type | meaning |
|---|---|---|
| id | string | `SW-#` walk route, `LOT-XXX` lot route, `T#-XXX` tier zone |
| name | string | |
| kind | string | walk_route, lot_route, tier_zone, road_route |
| tier | 1 to 4 | T1 life safety and accessibility, T2 primary circulation, T3 full service, T4 cleanup and haul. Drives the color. |
| owner | string | Athletics, EERC, Facilities, Housing, Parking, REA, Wellness (the seven owners on the 2024-25 snow map) |
| machine | string | unit assigned, matches assets |
| operator | string | |
| est_hours | number | modeled time from the route sheets |
| window_hours | number | time allowed before the tier deadline |
| needs_tracing | boolean | |
| notes | string | |

## assets.geojson (Points)

| field | type | meaning |
|---|---|---|
| id | string | `AST-##` fixed things, `EQ-##` equipment |
| name | string | |
| type | string | facility, material_storage, equipment, hydrant, salt_box, irrigation, tree, other. Drives the color. |
| status | string | ok, in_service, down, needs_repair, unknown |
| equipment_class | string | equipment only: mower, utility, loader, blower, truck |
| home | string | equipment only: where it is parked |
| needs_tracing | boolean | |
| notes | string | |

Equipment points all sit on the Grounds shop right now. The map spreads them out a little so each one can be clicked. When a unit is moved or staged somewhere for the season, move its point.

## config.json

`layers` lists the files to load and whether each starts turned on. `mowing_category_colors` and `snow_tier_colors` map category and tier to hex colors. `work_status_options` is the status list in the work tracker.

## Work log files (work/*.json)

Exported from the map. Shape:

```json
{ "exported": "2026-09-06T18:00:00Z", "device": "...", "entries": {
  "MOW-01": { "status": "done", "note": "", "who": "Mason", "at": "2026-09-06T17:55:00Z", "name": "UND Green Space (core campus)", "layer": "mowing_areas" }
}}
```
