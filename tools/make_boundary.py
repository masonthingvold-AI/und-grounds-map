"""
Build a starting campus boundary from the UND-owned parcels near main campus,
padded about two blocks. Mason redraws this by hand on the iPad; this only
gives him something to start from. Run: python3 tools/make_boundary.py
"""
import json, os
D = os.path.join(os.path.dirname(__file__), "..", "data")
parcels = json.load(open(os.path.join(D, "parcels.geojson")))
xs, ys = [], []
for f in parcels["features"]:
    g = f["geometry"]; rings = g["coordinates"] if g["type"] == "Polygon" else [r for p in g["coordinates"] for r in p]
    for ring in rings:
        for x, y in ring:
            if 47.905 < y < 47.940 and -97.105 < x < -97.050:   # main campus only, skip airport and far parcels
                xs.append(x); ys.append(y)
pad_x, pad_y = 0.0030, 0.0020   # roughly two blocks
box = [[min(xs)-pad_x, min(ys)-pad_y], [max(xs)+pad_x, min(ys)-pad_y], [max(xs)+pad_x, max(ys)+pad_y], [min(xs)-pad_x, max(ys)+pad_y], [min(xs)-pad_x, min(ys)-pad_y]]
fc = {"type": "FeatureCollection", "features": [{"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [box]},
      "properties": {"id": "BND-01", "name": "Main campus boundary", "kind": "campus", "site": "main", "needs_tracing": True,
                     "notes": "Starting box around UND-owned parcels plus about two blocks. Redraw by hand to the real edge. Everything outside is dimmed."}}]}
json.dump(fc, open(os.path.join(D, "boundary.geojson"), "w"), indent=2)
print("boundary box", box[0], box[2])
