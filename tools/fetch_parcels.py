"""
Pull every parcel the City of Grand Forks lists under UND-related owners from the
city's ArcGIS open data (Parcel Owner Info Active) into data/parcels.geojson.
Uses curl because the Mac's Python lacks certificates. Run: python3 tools/fetch_parcels.py
"""
import json, subprocess, urllib.parse, os, collections
D = os.path.join(os.path.dirname(__file__), "..", "data")
U = "https://services5.arcgis.com/tEvkdB384rqq9Ook/arcgis/rest/services/OpenDataLayers/FeatureServer/50/query"
WHERE = ("(UPPER(OwnerName1) LIKE 'UNIVERSITY OF N%' OR UPPER(OwnerName1) LIKE 'STATE OF NORTH DAKOTA%' "
         "OR UPPER(OwnerName1) LIKE 'NORTH DAKOTA STATE BOARD OF HIGHER%' OR UPPER(OwnerName1) LIKE 'UND ALUMNI%' "
         "OR UPPER(OwnerName1) LIKE 'UND AEROSPACE%' OR UPPER(OwnerName1) LIKE 'NORTH DAKOTA DELTA UPSILON%' "
         "OR UPPER(OwnerName1) LIKE 'DELTA TAU DELTA ALUMNI%' OR UPPER(OwnerName1) LIKE '%ENGELSTAD%' "
         "OR UPPER(OwnerName1) LIKE '%BRONSON%' OR UPPER(OwnerName1) LIKE 'UND %' OR UPPER(OwnerName1) LIKE 'UND,%' "
         "OR UPPER(OwnerName1) LIKE '%UNIVERSITY OF NORTH DAKOTA%' OR UPPER(OwnerName1) LIKE '%RESEARCH FOUNDATION%')")
p = {"where": WHERE, "outFields": "OwnerName1,PhysicalAddress,LandUse,LegalDescription,ParcelNumber,parcelarea", "f": "geojson", "outSR": "4326", "resultRecordCount": 2000, "geometryPrecision": 6}
d = json.loads(subprocess.run(["curl", "-s", U + "?" + urllib.parse.urlencode(p)], capture_output=True, text=True).stdout)
def cls(n):
    n = (n or "").upper()
    if n.startswith("UND AEROSPACE"): return "aerospace_foundation"
    if n.startswith("UND ALUMNI"): return "alumni_foundation"
    if "DELTA" in n: return "greek"
    if "ENGELSTAD" in n: return "rea"
    if "BRONSON" in n: return "bronson"
    if "RESEARCH FOUNDATION" in n or ("FOUNDATION" in n and "UND" in n): return "alumni_foundation"
    return "und_state"
out = []
for i, f in enumerate(d["features"]):
    a = f["properties"]
    f["properties"] = {"id": f"PAR-{i+1:03d}", "name": (a.get("PhysicalAddress") or a.get("LegalDescription") or "parcel").split("\r")[0][:60],
        "owner_name": a.get("OwnerName1"), "owner_class": cls(a.get("OwnerName1")), "parcel": a.get("ParcelNumber"), "address": a.get("PhysicalAddress"),
        "land_use": a.get("LandUse"), "acres": round((a.get("parcelarea") or 0) / 43560, 2), "legal": (a.get("LegalDescription") or "").replace("\r\n", " "),
        "source": "City of Grand Forks Parcel Owner Info Active", "needs_tracing": False, "site": "main", "notes": ""}
    out.append(f)
json.dump({"type": "FeatureCollection", "features": out}, open(os.path.join(D, "parcels.geojson"), "w"))
print(len(out), "parcels", dict(collections.Counter(f["properties"]["owner_class"] for f in out)))
