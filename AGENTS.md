# Working in this repo (for Claude, ChatGPT, and people)

This repo is shared between Mason, Claude, and ChatGPT. Any of the three may edit it. Follow these rules so the map keeps working and nobody's edits get lost.

## What this is

An interactive map for UND Facilities Management, Grounds (landscaping and snow removal). One HTML page (`index.html`) reads GeoJSON files in `data/` and draws them on a satellite or street basemap. The crew uses it on phones, the supervisor uses it on a laptop. The map itself has no build framework. The operations app behind it runs on Supabase (see docs/adr-001-architecture.md and docs/supabase-setup.md).

## Layout

```
index.html              the whole app, one file, plain HTML/CSS/JS
vendor/                 Leaflet 1.9.4 and Leaflet.draw 1.0.4, copied in so the map works without a CDN
data/config.json        title, map center, layer list, colors, status options
data/mowing_areas.geojson
data/snow_routes.geojson
data/assets.geojson     equipment, storage, hydrants, salt boxes, anything with a point
data/parcels.geojson    every parcel the City of Grand Forks lists andowned by UND, the State for UND, the Alumni Foundation, the Aerospace Foundation, or a Greek alumni corp. Pulled from the city's ArcGIS open data. Re-pull with tools/fetch_parcels.py, do not hand edit geometry.
data/boundary.geojson   hand drawn lines: the campus edge (kind=campus, everything outside it is dimmed), zones, crew areas, keep-out and sprayedeme an, flower beds
tools/serve.py          local server so an iPad or phone on the same Wi-Fi can open the map and save straight back into data/
tools/make_boundary.py  builds a starting campus box from the parcels; Mason redraws it by hand
tools/extract_mowing_map.py  lifts the colored areas out of the 2025 mowing map PDF into data/overlays/ (the map's Edit mode overlays the drawing and imports them)
tools/audit.py          security audit against the live project: RLS, grants, function allow list, direct writes, storage, cron
data/overlays/          the mowing map drawing (png) and its colored regions (json, pixel coordinates); imported through the map, never hand edited
data/bundle.js          GENERATED from the files above by tools/build.py. Never hand edit.
tools/build.py          rebuilds data/bundle.js and validates the geojson
tools/seed_data.py      the original placeholder data. Do not re-run once real shapes exist.
work/                   exported work logs from the map (work-log-YYYY-MM-DD.json)
docs/data-schema.md     field definitions for every layer
docs/app-spec-v0.2.md   Claude's spec for the shared workforce app (roles, certs, assignments, snow, equipment log, Ecopia, My UND)
docs/product-brief-v0.1.md  ChatGPT/Codex product brief for the same app (P0/P1/P2, acceptance criteria, records model)
docs/adr-001-architecture.md  THE accepted architecture decision. Read before any backend or app-shell work. Blueprints are references only.
docs/technical-blueprint-v0.1.md  Claude's blueprint (reference, corrected by the ADR)
docs/technical-blueprint-codex-v0.2.md  Codex's blueprint (reference; Codex commits it from its checkout)
docs/api-contract.md    THE client contract: functions, views, errors, offline rules, realtime. Codex builds against this and nothing else.
docs/api-contract-changes.md  where to propose a contract change before building on it
docs/supabase-setup.md  how the Supabase project is configured and the commands to migrate, seed, test, reset
supabase/migrations/    the database, numbered SQL files, applied by tools/migrate.py (Claude's area per the ADR). 0011 pulls calendar.und.edu daily with pg_cron
tools/migrate.py        apply migrations to the project in .env
tools/seed_supabase.py  load data/*.geojson into zones (versioned) and assets
tools/smoke_test.py     end to end test with synthetic users
.env                    secrets, never committed; .env.example shows the keys
```

## Project hub and checkouts

Mason keeps a hub folder at `~/Desktop/UND Grounds` with shortcuts: `Claude` (this repo on the Mac), `Codex` (a separate checkout for ChatGPT/Codex once cloned from GitHub), `Reference Materials` (the original source PDFs), `Handoffs` (planning notes). GitHub is the shared truth: https://github.com/masonthingvold-AI/und-grounds-map. Each assistant works in its own checkout, commits in plain English, and pulls before starting. Decisions go in `docs/`, not in chat.

## Rules

1. Edit the `.geojson` files, never `data/bundle.js`. After any data change run `python3 tools/build.py`. If you cannot run Python (ChatGPT in a chat without code execution), say so in your reply and Mason or Claude will rebuild. The page still works on GitHub Pages without a rebuild because it fetches the `.geojson` files directly; the bundle only matters when the page is opened from a file on a computer.
2. Every feature needs a unique `id` and a `name`. IDs are stable. Do not renumber or reuse an ID after deleting a feature. Prefixes: `MOW-`, `SW-` (walk routes), `LOT-`, `T#-` (tier zones), `AST-`, `EQ-`.
3. `parcels` geometry comes from the city and is never hand edited; if it looks wrong, note it and re-pull. `boundary` is hand drawn by Mason and is the operational truth for the map edge.
3b. `needs_tracing: true` means the shape is a placeholder. Only set it to `false` when someone handactually redrawn the shape on the imagery in Edit mode. Never clear it just to make the banner go away.
4. Acreage in `mowing_areas` comes from the UND mowing map (March 3, 2026). Treat it as the number of record. The map also shows the area of the drawn polygon so the two can be compared.
5. Do not invent equipment, routes, or assets. If something is unknown, leave the field empty ("") and put the question in `notes`.
6. Snow tiers, triggers, and targets come from the Snow Priority Standard draft in the "UND Landscaping" Claude project. Keep them consistent: T1 open 6:30 a.m., T2 open 7:30 a.m., T3 noon next day, T4 by request.
7. Coordinates are `[longitude, latitude]` in GeoJSON. Grand Forks is roughly lon -97.07, lat 47.92. If you see them swapped, fix them.
8. Keep `index.html` a single file with no framework and no build step. Vanilla JS. It has to open from a phone and from a double-clicked file.
9. Colors and type: UND Green `#009A44`, deep green `#00722F`, UND Gray `#AEAEAE`. Oswald for headings, Helvetica Neue / Arial for body. No em dashes in any text.
10. Commit messages: one line, plain English, say what changed and why. Example: `Trace MOW-03 REA grounds on imagery, clear needs_tracing`.

## How edits usually happen

- In the map (fastest): open `index.html` in Chrome or Edge, click Edit mode, click Connect repo folder and pick the repo (or its `data/` folder). Draw, reshape, click a shape and change its details in the Selected panel (they apply as you type). Cmd/Ctrl+S writes every `.geojson` and `bundle.js` straight into `data/`. Then commit. Safari cannot write files, so there Download all data replaces the files by hand and you run `tools/build.py`.
- On the iPad: on the Mac run `python3 tools/serve.py`, open the address it prints on the iPad, tap Edit mode, draw. Save (or the Save button) writes to the Mac. No file picker needed.
- Scope: only what UND owns plus about two blocks. The `boundary` layer's `campus` polygon is the edge; the map dims everything outside it. Parcels are the city's record of ownership and are the reference for where that edge should be.
- Site filter: every feature handa `site` (main, greek, memorial, airport, offsite). The map scope is what UND owns; Greek row and Memorial Village / Fieldhouse are included with `ownership: future` in case that changes. Airport and other offsite sites exist in config but have no data yet.
- Work in the field: crew sets a status and note on any feature. That is saved on their phone only. Export work log puts it in a JSON file to commit under `work/`. Copy summary puts a plain text version on the clipboard to paste into Claude or ChatGPT.
- From an AI: read the geojson, change properties or add features following the schema, write the file back, ask for a rebuild if you cannot run it.

## Open questions the data still needs (carry these forward, do not delete)

- Real polygon for every mowing area (all 11 are placeholders)
- Sidewalk network by segment with widths
- Lot inventory with square footage and which stalls are accessible
- Designated ADA routes (Tier 1 is written around a list that does not exist yet)
- Snow storage corners for each lot
- What attachments are on the three Bobcats and whether any lot unit handa pusher box
- Crew names and shift assignments for each route
- The ~60 unlabeled red point symbols on the 2024-25 snow map (hydrants? salt boxes?)
