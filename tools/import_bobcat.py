#!/usr/bin/env python3
"""Load data/equipment/bobcat-fleet.csv into public.assets. Idempotent: rows are matched by id and refreshed.

  python3 tools/import_bobcat.py           load or update
  python3 tools/import_bobcat.py --check   report only

The CSV was read from Mason's My Equipment list on shop.bobcat.com (23 items, September 7, 2026). Edit the CSV, rerun.
Photos, hours, year, and status are edited in the map's Equipment panel and are never touched here.
"""
import csv, json, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from migrate import connect, ROOT

def main():
    check = "--check" in sys.argv
    rows = list(csv.DictReader(open(ROOT / "data/equipment/bobcat-fleet.csv", newline="")))
    with connect() as conn:
        for r in rows:
            compat = [c for c in r["compatible_with"].split(";") if c]
            conn.execute("""insert into public.assets(id, name, asset_type, class, make, model, serial, required_capability_code, compatible_with, notes, attrs, active)
                            values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,true)
                            on conflict (id) do update set name = excluded.name, asset_type = excluded.asset_type, class = excluded.class, make = excluded.make,
                              model = excluded.model, serial = excluded.serial, required_capability_code = excluded.required_capability_code,
                              compatible_with = excluded.compatible_with, notes = coalesce(public.assets.notes, excluded.notes),
                              attrs = public.assets.attrs || excluded.attrs, active = true""",
                         (r["id"], r["name"], r["asset_type"], r["class"], r["make"], r["model"], r["serial"], r["required_capability_code"] or None,
                          compat, r["notes"] or None, json.dumps({"source": "bobcat_shop"})))
        n = conn.execute("select count(*) from public.assets where active").fetchone()[0]
        if check: conn.rollback()
    print(f"{'would ' if check else ''}load {len(rows)} rows; active assets now {n}")

if __name__ == "__main__": main()
