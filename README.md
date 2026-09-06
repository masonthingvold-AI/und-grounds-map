# UND Grounds Map

Interactive campus map for UND Facilities Management, Grounds. Mowing areas, snow routes, equipment, and a simple work tracker, on satellite or street basemaps. Works on a phone in the field and on a laptop at a desk.

**Open it:** double-click `index.html`, or use the GitHub Pages link once it is turned on.

## What it does

- Satellite and street basemaps, switch in the top right corner
- Layers: mowing areas (colored by category, with acreage), snow routes (colored by tier), equipment and assets
- Click anything to see its details
- Find: search by name, ID, crew, category, anything in the data
- Work tracking: set a status and a note on any area or route, mark done, export the log, or copy a summary to paste into Claude or ChatGPT
- Where am I: GPS dot on the map for the crew
- Edit mode: trace real shapes on the imagery, edit details, export the layer back to `data/`
- Print: prints the map view

## Status

Every shape is a placeholder right now. The mowing acreages are real (from the March 2026 UND mowing map); the outlines are not. The first job is to trace each mowing area on the satellite view in Edit mode and clear its `needs tracing` flag. Dashed outlines on the map mean not traced yet.

## Editing

See `AGENTS.md`. Short version: edit the `.geojson` files in `data/`, run `python3 tools/build.py`, commit.

## Credits

Built with Leaflet and Leaflet.draw. Basemaps from OpenStreetMap contributors and Esri World Imagery. Mowing categories and acreages from UND Facilities Management's mowing map. Snow tiers from the Snow Priority Standard draft.
