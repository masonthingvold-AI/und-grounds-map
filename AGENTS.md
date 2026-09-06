# Working in this repo (for Claude, ChatGPT, and people)

This repo is shared between Mason, Claude, and ChatGPT. Any of the three may edit it. Follow these rules so the map keeps working and nobody's edits get lost.

## What this is

An interactive map for UND Facilities Management, Grounds (landscaping and snow removal). One HTML page (`index.html`) reads GeoJSON files in `data/` and draws them on a satellite or street basemap. The crew uses it on phones, the supervisor uses it on a laptop. There is no server, no database, no build framework.

## Layout

```
index.html              the whole app, one file, plain HTML/CSS/JS
vendor/                 Leaflet 1.9.4 and Leaflet.draw 1.0.4, copied in so the map works without a CDN
data/config.json        title, map center, layer list, colors, status options
data/mowing_areas.geojson
data/snow_routes.geojson
data/assets.geojson     equipment, storage, hydrants, salt boxes, anything with a point
data/bundle.js          GENERATED from the files above by tools/build.py. Never hand edit.
tools/build.py          rebuilds data/bundle.js and validates the geojson
tools/seed_data.py      the original placeholder data. Do not re-run once real shapes exist.
work/                   exported work logs from the map (work-log-YYYY-MM-DD.json)
docs/data-schema.md     field definitions for every layer
```

## Rules

1. Edit the `.geojson` files, never `data/bundle.js`. After any data change run `python3 tools/build.py`. If you cannot run Python (ChatGPT in a chat without code execution), say so in your reply and Mason or Claude will rebuild. The page still works on GitHub Pages without a rebuild because it fetches the `.geojson` files directly; the bundle only matters when the page is opened from a file on a computer.
2. Every feature needs a unique `id` and a `name`. IDs are stable. Do not renumber or reuse an ID after deleting a feature. Prefixes: `MOW-`, `SW-` (walk routes), `LOT-`, `T#-` (tier zones), `AST-`, `EQ-`.
3. `needs_tracing: true` means the shape is a placeholder. Only set it to `false` when someone has actually redrawn the shape on the imagery in Edit mode. Never clear it just to make the banner go away.
4. Acreage in `mowing_areas` comes from the UND mowing map (March 3, 2026). Treat it as the number of record. The map also shows the area of the drawn polygon so the two can be compared.
5. Do not invent equipment, routes, or assets. If something is unknown, leave the field empty ("") and put the question in `notes`.
6. Snow tiers, triggers, and targets come from the Snow Priority Standard draft in the "UND Landscaping" Claude project. Keep them consistent: T1 open 6:30 a.m., T2 open 7:30 a.m., T3 noon next day, T4 by request.
7. Coordinates are `[longitude, latitude]` in GeoJSON. Grand Forks is roughly lon -97.07, lat 47.92. If you see them swapped, fix them.
8. Keep `index.html` a single file with no framework and no build step. Vanilla JS. It has to open from a phone and from a double-clicked file.
9. Colors and type: UND Green `#009A44`, deep green `#00722F`, UND Gray `#AEAEAE`. Oswald for headings, Helvetica Neue / Arial for body. No em dashes in any text.
10. Commit messages: one line, plain English, say what changed and why. Example: `Trace MOW-03 REA grounds on imagery, clear needs_tracing`.

## How edits usually happen

- In the map: open `index.html`, click Edit mode, pick the layer, draw or reshape, click a shape to edit its details, then Export this layer as GeoJSON. Replace the matching file in `data/` with the download. Run `tools/build.py`. Commit.
- Work in the field: crew sets a status and note on any feature. That is saved on their phone only. Export work log puts it in a JSON file to commit under `work/`. Copy summary puts a plain text version on the clipboard to paste into Claude or ChatGPT.
- From an AI: read the geojson, change properties or add features following the schema, write the file back, ask for a rebuild if you cannot run it.

## Open questions the data still needs (carry these forward, do not delete)

- Real polygon for every mowing area (all 11 are placeholders)
- Sidewalk network by segment with widths
- Lot inventory with square footage and which stalls are accessible
- Designated ADA routes (Tier 1 is written around a list that does not exist yet)
- Snow storage corners for each lot
- What attachments are on the three Bobcats and whether any lot unit has a pusher box
- Crew names and shift assignments for each route
- The ~60 unlabeled red point symbols on the 2024-25 snow map (hydrants? salt boxes?)
