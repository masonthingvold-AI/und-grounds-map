"""
Serve the map on the local network so a phone or iPad can open it, and accept
saves from the map's Edit mode (Cmd/Ctrl+S or the Save button) so tracing on the
iPad writes straight into data/ on this computer.

Run from the repo folder:   python3 tools/serve.py
Then on the iPad (same Wi-Fi) open the address it prints, e.g. http://10.0.0.12:8765
"""
import json, os, socket, sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DATA = os.path.join(ROOT, "data")
os.chdir(ROOT)
ALLOWED = {"boundary","parcels","mowing_areas","snow_routes","assets"}
class H(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store"); super().end_headers()
    def do_POST(self):
        if self.path != "/save": self.send_error(404); return
        n = int(self.headers.get("Content-Length", 0)); body = json.loads(self.rfile.read(n))
        written = []
        for key, fc in body.get("layers", {}).items():
            if key not in ALLOWED and not key.replace("_","").isalnum(): continue
            with open(os.path.join(DATA, f"{key}.geojson"), "w") as f: json.dump(fc, f, indent=2)
            written.append(key)
        if "bundle" in body:
            with open(os.path.join(DATA, "bundle.js"), "w") as f: f.write(body["bundle"])
            written.append("bundle.js")
        out = json.dumps({"ok": True, "written": written}).encode()
        self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
        print("saved", written)
    def log_message(self, *a): pass
def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try: s.connect(("8.8.8.8", 80)); return s.getsockname()[0]
    except Exception: return "127.0.0.1"
    finally: s.close()
port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
print(f"UND Grounds Map server\n  on this computer: http://localhost:{port}\n  on the iPad or phone (same Wi-Fi): http://{lan_ip()}:{port}\nCtrl+C to stop.")
ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
