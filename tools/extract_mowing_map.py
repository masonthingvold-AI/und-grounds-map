#!/usr/bin/env python3
"""Lift the colored mowing areas out of the UND mowing map PDF.

Writes data/overlays/mowing-map-2025.png (the drawing, for the see-through overlay in the map) and
data/overlays/mowing-map-2025.json (one polygon per colored region, in that PNG's pixel coordinates, with its legend class).
The map's Edit mode places the overlay on the satellite view and imports these polygons as mowing areas.

  python3 -m pip install pymupdf opencv-python-headless shapely numpy
  python3 tools/extract_mowing_map.py "path/to/Mowing Map 2025UND  Greenspace 2.pdf"
"""
import sys, json, pathlib
import numpy as np, cv2, fitz
from shapely.geometry import Polygon, mapping
from shapely.ops import unary_union

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "data" / "overlays"; OUT.mkdir(parents=True, exist_ok=True)
DPI = 300
# legend class -> fill color (RGB) as rendered
CLASSES = {"UND Green Space": (0x78,0xb8,0x38), "Golf Course": (0xc8,0xa8,0x88), "Foundation": (0xf8,0xe8,0xa8), "Housing": (0x98,0x48,0xd8),
           "Primary Housing": (0x38,0x28,0xf8), "Greenway": (0xf8,0xf8,0x08), "Sports Fields": (0xf8,0x08,0x08), "REA": (0xf8,0x38,0x98),
           "EERC": (0x88,0xd8,0xf8), "Wellness": (0xd8,0x98,0x28), "Alumni": (0x48,0x78,0x88)}
MIN_PX_AREA = 900          # drop specks smaller than this at 300 dpi (about 0.15 acre)
THRESHOLD = {"Alumni": 40}  # Alumni slate is close to road gray; everything else 70
METERS_PER_PIXEL = 0.828    # the drawing is to scale: total colored pixels against the legend acreage

def main(pdf):
    doc = fitz.open(pdf); page = doc[0]
    pix = page.get_pixmap(matrix=fitz.Matrix(DPI/72, DPI/72), alpha=False)
    img = np.frombuffer(pix.samples, np.uint8).reshape(pix.height, pix.width, 3)   # RGB
    H, W = img.shape[:2]
    frame_x1 = int(W * 0.79)                     # main map frame ends before the inset and legend
    out = {"source": pathlib.Path(pdf).name, "dpi": DPI, "width": W, "height": H, "frame": [0, 0, frame_x1, H], "classes": {}, "regions": []}
    rgb = img.astype(int)
    for name, (r, g, b) in CLASSES.items():
        d = np.abs(rgb - np.array([r, g, b])).sum(axis=2)
        mask = (d < THRESHOLD.get(name, 70)).astype(np.uint8); mask[:, frame_x1:] = 0
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
        cnts, hier = cv2.findContours(mask, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE)
        n = 0
        if hier is not None:
            hier = hier[0]
            for i, c in enumerate(cnts):
                if hier[i][3] != -1 or cv2.contourArea(c) < MIN_PX_AREA: continue
                holes = []; j = hier[i][2]
                while j != -1:
                    if cv2.contourArea(cnts[j]) > MIN_PX_AREA: holes.append(cnts[j].reshape(-1, 2))
                    j = hier[j][0]
                try:
                    p = Polygon(c.reshape(-1, 2), holes).buffer(0).simplify(1.5)
                except Exception:
                    continue
                if p.is_empty or p.area < MIN_PX_AREA: continue
                polys = [p] if p.geom_type == "Polygon" else list(p.geoms)
                for q in polys:
                    out["regions"].append({"class": name, "px_area": round(q.area), "geometry": mapping(q)}); n += 1
        out["classes"][name] = {"rgb": [r, g, b], "regions": n}
        print(f"{name:16} {n:3} regions")
    # the drawing itself, half size, for the overlay
    small = cv2.resize(img, (W // 2, H // 2), interpolation=cv2.INTER_AREA)
    cv2.imwrite(str(OUT / "mowing-map-2025.png"), cv2.cvtColor(small, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_PNG_COMPRESSION, 6])
    out["overlay_scale"] = 0.5; out["meters_per_pixel"] = METERS_PER_PIXEL
    (OUT / "mowing-map-2025.json").write_text(json.dumps(out, separators=(",", ":")))
    print("regions", len(out["regions"]), "png", (W // 2, H // 2))

if __name__ == "__main__":
    main(sys.argv[1])
