"""
Seed the data/ folder with DRAFT geometry.

Every shape here is an approximate placeholder drawn from landmark coordinates,
not from a survey or UND's GIS. Each feature carries "needs_tracing": true until
someone redraws it on the satellite imagery inside the map (Edit mode) and the
flag is cleared. Acreages for mowing areas come from the March 3, 2026
"UND Green Space" mowing map and are authoritative even where the polygon is not.

Run:  python3 tools/seed_data.py
Then: python3 tools/build.py
"""
import json, os

ROOT = os.path.join(os.path.dirname(__file__), "..", "data")

def box(lat, lon, dlat, dlon):
    """Rectangle polygon centered on (lat, lon), half-sizes in degrees."""
    return {"type": "Polygon", "coordinates": [[
        [lon - dlon, lat - dlat], [lon + dlon, lat - dlat],
        [lon + dlon, lat + dlat], [lon - dlon, lat + dlat],
        [lon - dlon, lat - dlat]]]}

def feat(geom, **props):
    props.setdefault("site", "main")
    return {"type": "Feature", "geometry": geom, "properties": props}

# ---------------------------------------------------------------- mowing areas
# Categories and acreages straight off the 2025/2026 mowing map legend.
mowing = [
    feat(box(47.9238, -97.0745, 0.0028, 0.0075), id="MOW-01", name="UND Green Space (core campus)",
         category="UND Green Space", acres=107.90, crew="", frequency="weekly", mower="Toro 4100 D 10'",
         ownership="UND", needs_tracing=True, notes="Core academic campus between University Ave and 6th Ave N. Split into sub-areas when traced."),
    feat(box(47.9250, -97.0885, 0.0012, 0.0025), id="MOW-02", name="Sports Fields Green Space",
         category="Sports Fields", acres=8.40, crew="", frequency="2x weekly", mower="Toro Sidewinder / 3280 D",
         needs_tracing=True, notes="Practice and game fields. Height and stripe pattern differ from general turf."),
    feat(box(47.9252, -97.0925, 0.0010, 0.0020), id="MOW-03", name="REA grounds",
         category="REA", acres=5.93, crew="", frequency="weekly", mower="",
         needs_tracing=True, notes="Ralph Engelstad Arena. REA is a separate owner on the snow map."),
    feat(box(47.9265, -97.0670, 0.0009, 0.0018), id="MOW-04", name="EERC grounds",
         category="EERC", acres=5.43, crew="", frequency="weekly", mower="",
         needs_tracing=True, notes="Energy & Environmental Research Center. Separate owner on the snow map."),
    feat(box(47.9210, -97.0960, 0.0015, 0.0040), id="MOW-05", name="Foundation property",
         category="Foundation", acres=24.39, crew="", frequency="biweekly", mower="",
         needs_tracing=True, notes="UND Foundation land. Confirm which parcels grounds actually mows."),
    feat(box(47.9235, -97.0790, 0.0035, 0.0006), id="MOW-06", name="Greenway (English Coulee corridor)",
         category="Greenway", acres=13.00, crew="", frequency="biweekly", mower="",
         needs_tracing=True, notes="Coulee banks and bike path edges. Slope work, check equipment."),
    feat(box(47.9170, -97.0800, 0.0025, 0.0060), id="MOW-07", name="Ray Richards Golf Course",
         category="Golf Course", acres=62.37, crew="", frequency="course schedule", mower="",
         needs_tracing=True, notes="Course maintains its own greens and fairways. Record what grounds is responsible for."),
    feat(box(47.9215, -97.0700, 0.0012, 0.0030), id="MOW-08", name="Primary Housing",
         category="Primary Housing", acres=15.19, crew="", frequency="weekly", mower="",
         needs_tracing=True, notes="Residence hall grounds south of University Ave."),
    feat(box(47.9195, -97.0640, 0.0015, 0.0030), id="MOW-09", name="Housing (apartments)",
         category="Housing", acres=27.02, crew="", frequency="weekly", mower="",
         needs_tracing=True, notes="Apartment complexes. Housing is a separate owner on the snow map."),
    feat(box(47.9213, -97.0805, 0.0006, 0.0012), id="MOW-10", name="Gorecki Alumni Center",
         category="Alumni", acres=1.32, crew="", frequency="weekly", mower="",
         needs_tracing=True, notes="High-visibility. Trim same day as mow."),
    feat(box(47.9200, -97.0770, 0.0008, 0.0015), id="MOW-11", name="Wellness Center grounds",
         category="Wellness", acres=2.66, crew="", frequency="weekly", mower="",
         needs_tracing=True, notes="Wellness is a separate owner on the snow map."),
    feat(box(47.9247, -97.0815, 0.0007, 0.0025), id="MOW-12", name="Greek row",
         category="UND Green Space", acres="", crew="", frequency="weekly", mower="", site="greek", ownership="future",
         needs_tracing=True, notes="Fraternity and sorority houses. Not UND owned today; included in case that changes. Record which lawns grounds actually touches."),
    feat(box(47.9243, -97.0768, 0.0006, 0.0012), id="MOW-13", name="Memorial Village",
         category="UND Green Space", acres="", crew="", frequency="weekly", mower="", site="memorial", ownership="future",
         needs_tracing=True, notes="The Hyslop side of Memorial Village. Included in case UND ownership changes."),
    feat(box(47.9243, -97.0745, 0.0006, 0.0010), id="MOW-14", name="Fieldhouse",
         category="UND Green Space", acres="", crew="", frequency="weekly", mower="", site="memorial", ownership="future",
         needs_tracing=True, notes="Memorial Village Fieldhouse side. Included in case UND ownership changes."),
]

# ------------------------------------------------------------------ snow routes
# Tiers from the Snow Priority Standard draft (v0.2). Routes are placeholders
# for the 14 machine routes; walk routes SW-1..SW-6 named in the redesign notes.
def line(pts):
    return {"type": "LineString", "coordinates": [[lon, lat] for lat, lon in pts]}

snow = [
    feat(line([(47.9222, -97.0800), (47.9222, -97.0700), (47.9245, -97.0700), (47.9245, -97.0760)]),
         id="SW-1", name="SW-1 Core Walks", kind="walk_route", tier=1, owner="Facilities",
         machine="", operator="", est_hours=4.7, window_hours=4.5, needs_tracing=True,
         notes="Lands 0.2 hr over its window in v0.2. Candidate to absorb Gorecki frontage off SW-6."),
    feat(line([(47.9230, -97.0690), (47.9230, -97.0660), (47.9260, -97.0660)]),
         id="SW-2", name="SW-2 East Walks & EERC", kind="walk_route", tier=2, owner="Facilities",
         machine="", operator="", est_hours=0, window_hours=5.0, needs_tracing=True, notes=""),
    feat(line([(47.9215, -97.0730), (47.9200, -97.0730), (47.9200, -97.0680)]),
         id="SW-3", name="SW-3 South Housing Walks", kind="walk_route", tier=2, owner="Housing",
         machine="", operator="", est_hours=0, window_hours=5.0, needs_tracing=True, notes=""),
    feat(line([(47.9240, -97.0800), (47.9260, -97.0800), (47.9260, -97.0880)]),
         id="SW-4", name="SW-4 North Walks", kind="walk_route", tier=2, owner="Facilities",
         machine="", operator="", est_hours=2.2, window_hours=5.0, needs_tracing=True,
         notes="Runs half empty (2.2 hr). Rebalance candidate."),
    feat(line([(47.9250, -97.0900), (47.9250, -97.0980), (47.9300, -97.1100)]),
         id="SW-5", name="SW-5 West Campus & Aerospace", kind="walk_route", tier=2, owner="Facilities",
         machine="", operator="", est_hours=5.9, window_hours=5.5, needs_tracing=True,
         notes="Over window. Split the airport hangar line off into its own route."),
    feat(line([(47.9213, -97.0830), (47.9213, -97.0780), (47.9225, -97.0780)]),
         id="SW-6", name="SW-6 Gorecki & Perimeter", kind="walk_route", tier=2, owner="Facilities",
         machine="", operator="", est_hours=2.0, window_hours=5.0, needs_tracing=True,
         notes="Runs half empty (2.0 hr). Move Gorecki and perimeter frontage to SW-1 tail."),
    feat(box(47.9238, -97.0745, 0.0028, 0.0075), id="T2-ROADS", name="Tier 2 roads and drive lanes",
         kind="tier_zone", tier=2, owner="Facilities", needs_tracing=True,
         notes="Campus Rd, Cornell, 2nd Ave N, Hamline, etc. Trigger 2 in. Open by 7:30 a.m."),
    feat(box(47.9250, -97.0910, 0.0010, 0.0030), id="LOT-REA", name="REA lots", kind="lot_route", tier=3, owner="REA",
         machine="", operator="", needs_tracing=True, notes="Pusher box if available. Snow storage corners not yet designated."),
    feat(box(47.9270, -97.0880, 0.0008, 0.0012), id="LOT-FAC", name="Facilities yard", kind="lot_route", tier=3, owner="Facilities",
         machine="", operator="", needs_tracing=True, notes="WO code 003."),
]

# ----------------------------------------------------------------------- assets
def pt(lat, lon):
    return {"type": "Point", "coordinates": [lon, lat]}

assets = [
    feat(pt(47.9272, -97.0885), id="AST-01", name="Grounds & Landscaping shop", type="facility",
         status="ok", needs_tracing=True, notes="Equipment home base. Transportation, Grounds, Bus Storage, Recycling cluster."),
    feat(pt(47.9268, -97.0875), id="AST-02", name="Salt / sand storage", type="material_storage",
         status="unknown", needs_tracing=True, notes="Confirm location and capacity. WO code 010 materials."),
    feat(pt(47.9272, -97.0885), id="EQ-01", name="Toro 4100 D 10' (2013)", type="equipment", equipment_class="mower",
         status="in_service", home="Grounds shop", needs_tracing=False, notes="From Major Equipment list."),
    feat(pt(47.9272, -97.0885), id="EQ-02", name="Toro 4100 D 10' (2016)", type="equipment", equipment_class="mower",
         status="in_service", home="Grounds shop", needs_tracing=False, notes=""),
    feat(pt(47.9272, -97.0885), id="EQ-03", name="Toro 4100 D 10'", type="equipment", equipment_class="mower",
         status="in_service", home="Grounds shop", needs_tracing=False, notes="Year not recorded."),
    feat(pt(47.9272, -97.0885), id="EQ-04", name="Toro 4100 D 10'", type="equipment", equipment_class="mower",
         status="in_service", home="Grounds shop", needs_tracing=False, notes="Year not recorded."),
    feat(pt(47.9272, -97.0885), id="EQ-05", name="Toro 3280 D 6' (2013)", type="equipment", equipment_class="mower",
         status="in_service", home="Grounds shop", needs_tracing=False, notes=""),
    feat(pt(47.9272, -97.0885), id="EQ-06", name="Toro 3280 D 6' (2016)", type="equipment", equipment_class="mower",
         status="in_service", home="Grounds shop", needs_tracing=False, notes=""),
    feat(pt(47.9272, -97.0885), id="EQ-07", name="Toro Sidewinder (2017, soccer)", type="equipment", equipment_class="mower",
         status="in_service", home="Grounds shop", needs_tracing=False, notes="Sports fields."),
    feat(pt(47.9272, -97.0885), id="EQ-08", name="Toro 3200 Workman (2007)", type="equipment", equipment_class="utility",
         status="in_service", home="Grounds shop", needs_tracing=False, notes=""),
    feat(pt(47.9272, -97.0885), id="EQ-09", name="Toro 3200 Workman (2008)", type="equipment", equipment_class="utility",
         status="in_service", home="Grounds shop", needs_tracing=False, notes=""),
    feat(pt(47.9272, -97.0885), id="EQ-10", name="Toro 3200 Workman (2013)", type="equipment", equipment_class="utility",
         status="in_service", home="Grounds shop", needs_tracing=False, notes=""),
    feat(pt(47.9272, -97.0885), id="EQ-11", name="Gravely 5' mower (2022)", type="equipment", equipment_class="mower",
         status="in_service", home="Grounds shop", needs_tracing=False, notes=""),
    feat(pt(47.9272, -97.0885), id="EQ-12", name="Gravely 6' mower (2022)", type="equipment", equipment_class="mower",
         status="in_service", home="Grounds shop", needs_tracing=False, notes=""),
    feat(pt(47.9272, -97.0885), id="EQ-13", name="Grasshopper 360 (2018)", type="equipment", equipment_class="mower",
         status="in_service", home="Grounds shop", needs_tracing=False, notes=""),
    feat(pt(47.9272, -97.0885), id="EQ-14", name="Bobcat (2022) #1", type="equipment", equipment_class="loader",
         status="in_service", home="Grounds shop", needs_tracing=False, notes="Model not recorded. Snow-capable. Record attachments."),
    feat(pt(47.9272, -97.0885), id="EQ-15", name="Bobcat (2022) #2", type="equipment", equipment_class="loader",
         status="in_service", home="Grounds shop", needs_tracing=False, notes="Model not recorded."),
    feat(pt(47.9272, -97.0885), id="EQ-16", name="Bobcat (2022) #3", type="equipment", equipment_class="loader",
         status="in_service", home="Grounds shop", needs_tracing=False, notes="Model not recorded."),
]

def write(name, feats):
    fc = {"type": "FeatureCollection", "features": feats}
    with open(os.path.join(ROOT, name), "w") as f:
        json.dump(fc, f, indent=2)
    print("wrote", name, len(feats), "features")

write("mowing_areas.geojson", mowing)
write("snow_routes.geojson", snow)
write("assets.geojson", assets)
