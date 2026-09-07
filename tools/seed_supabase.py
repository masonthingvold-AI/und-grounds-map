#!/usr/bin/env python3
"""Load data/*.geojson into Supabase as zones (versioned) and assets. Idempotent.

  python3 tools/seed_supabase.py           load or update from the working tree
  python3 tools/seed_supabase.py --check   report only

Rules (AGENTS.md): the GeoJSON is the source of truth for the map; this script mirrors it into the database.
A zone gets a new zone_version only when its geometry changed. Properties are refreshed every run.
Parcels are a reference layer and are not loaded as zones.
"""
import json, sys, subprocess, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from migrate import connect, ROOT

CLASS_BY_SNOW_KIND = {"walk_route": "walk_route", "lot_route": "lot", "road_route": "road", "tier_zone": "tier_zone"}
CLASS_BY_BOUNDARY_KIND = {"campus": "campus", "zone": "other", "crew_area": "crew_area", "keep_out": "keep_out", "sprayed": "sprayed", "bed": "bed"}
ASSET_TYPE = {"facility": "facility", "material_storage": "fixed", "equipment": "machine", "hydrant": "fixed", "salt_box": "fixed",
              "irrigation": "fixed", "shutoff_valve": "fixed", "water_main": "fixed", "hazard": "fixed", "tree": "fixed", "other": "fixed"}

def commit_hash():
    try:
        return subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True).strip()
    except Exception:
        return "worktree"

def load(name):
    return json.load(open(ROOT / "data" / f"{name}.geojson"))["features"]

def zone_rows():
    rows = []
    for f in load("mowing_areas"):
        p = f["properties"]
        rows.append(dict(id=p["id"], name=p["name"], cls="mowing_area", site=p.get("site", "main"), ownership=p.get("ownership", "UND"),
                         season="landscaping", pl=None, ps=None, owner=p.get("category"), acres=num(p.get("acres")), attrs=p, geom=f["geometry"],
                         needs_tracing=bool(p.get("needs_tracing", True)), file="mowing_areas"))
    for f in load("snow_routes"):
        p = f["properties"]
        rows.append(dict(id=p["id"], name=p["name"], cls=CLASS_BY_SNOW_KIND.get(p.get("kind"), "other"), site=p.get("site", "main"), ownership="UND",
                         season="snow", pl=None, ps=int(p["tier"]) if str(p.get("tier","")).strip() else None, owner=p.get("owner"), acres=None, attrs=p, geom=f["geometry"],
                         needs_tracing=bool(p.get("needs_tracing", True)), file="snow_routes"))
    for f in load("boundary"):
        p = f["properties"]
        rows.append(dict(id=p["id"], name=p["name"], cls=CLASS_BY_BOUNDARY_KIND.get(p.get("kind"), "other"), site=p.get("site", "main"), ownership="UND",
                         season="either", pl=None, ps=None, owner=None, acres=None, attrs=p, geom=f["geometry"],
                         needs_tracing=bool(p.get("needs_tracing", True)), file="boundary"))
    return rows

def asset_rows():
    rows = []
    for f in load("assets"):
        p = f["properties"]
        t = p.get("type", "other")
        rows.append(dict(id=p["id"], name=p["name"], asset_type=ASSET_TYPE.get(t, "fixed"), cls=p.get("equipment_class") or t,
                         status={"ok": "in_service", "in_service": "in_service", "down": "down", "needs_repair": "needs_repair"}.get(p.get("status"), "unknown"),
                         home=p.get("home"), attrs=p, geom=f["geometry"]))
    return rows

def num(v):
    try: return float(v) if v not in (None, "") else None
    except (TypeError, ValueError): return None

def main():
    check = "--check" in sys.argv
    src = commit_hash()
    added = updated = versions = 0
    with connect() as conn:
        for z in zone_rows():
            cur = conn.execute("select z.id, st_equals(zv.geom, st_setsrid(st_geomfromgeojson(%s), 4326)) from public.zones z left join public.zone_versions zv on zv.id = z.current_version_id where z.id = %s", (json.dumps(z["geom"]), z["id"])).fetchone()
            if not check:
                conn.execute("""insert into public.zones(id, name, class, site, ownership, season, priority_landscaping, priority_snow, owner, acres_of_record, attrs)
                                values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                                on conflict (id) do update set name = excluded.name, class = excluded.class, site = excluded.site, ownership = excluded.ownership,
                                  season = excluded.season, priority_snow = excluded.priority_snow, owner = excluded.owner, acres_of_record = excluded.acres_of_record, attrs = excluded.attrs, active = true""",
                             (z["id"], z["name"], z["cls"], z["site"], z["ownership"], z["season"], z["pl"], z["ps"], z["owner"], z["acres"], json.dumps(z["attrs"])))
            same_geom = bool(cur and cur[1])
            if cur is None: added += 1
            else: updated += 1
            if not same_geom:
                versions += 1
                if not check:
                    conn.execute("select public.zone_version_create(%s, %s::jsonb, %s, %s, %s)",
                                 (z["id"], json.dumps(z["geom"]), f"geojson:data/{z['file']}.geojson@{src}", z["needs_tracing"], None))
            elif not check:
                conn.execute("update public.zone_versions set needs_tracing = %s where id = (select current_version_id from public.zones where id = %s) and needs_tracing <> %s",
                             (z["needs_tracing"], z["id"], z["needs_tracing"]))
        a_added = 0
        for a in asset_rows():
            if not check:
                conn.execute("""insert into public.assets(id, name, asset_type, class, status, home_zone_id, location, attrs)
                                values (%s,%s,%s,%s,%s,%s, st_setsrid(st_geomfromgeojson(%s),4326), %s)
                                on conflict (id) do update set name = excluded.name, asset_type = excluded.asset_type, class = excluded.class, status = excluded.status,
                                  home_zone_id = excluded.home_zone_id, location = excluded.location, attrs = excluded.attrs, active = true""",
                             (a["id"], a["name"], a["asset_type"], a["cls"], a["status"], None, json.dumps(a["geom"]), json.dumps(a["attrs"])))
            a_added += 1
        # anything no longer in the GeoJSON was a placeholder: deactivate it (history stays, nothing is deleted).
        # Machines and attachments are managed in the database (asset_upsert, tools/import_bobcat.py), never by this script.
        zone_ids = [z["id"] for z in zone_rows()]; asset_ids = [a["id"] for a in asset_rows()]
        if not check:
            conn.execute("update public.zones set active = false where active and not (id = any(%s))", (zone_ids,))
            conn.execute("update public.assets set active = false where active and asset_type in ('facility','fixed') and attrs ? 'type' and not (id = any(%s))", (asset_ids,))
        if check: conn.rollback()
        else: conn.commit()
        n = conn.execute("select count(*) from public.zones").fetchone()[0]
        nv = conn.execute("select count(*) from public.zone_versions").fetchone()[0]
        na = conn.execute("select count(*) from public.assets").fetchone()[0]
    print(f"{'would ' if check else ''}load: zones new {added}, existing {updated}, new geometry versions {versions}, assets {a_added}")
    print(f"database now: zones {n}, zone_versions {nv}, assets {na}")

if __name__ == "__main__":
    main()
