"""Uplink Settings: a local page in the browser to pick the AI, the library folder and the agents.

Serves settings.html on 127.0.0.1 only, with a one-time token, and closes after Save (or 30 minutes).
Usage: settings.py
"""
import json
import secrets
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # -I leaves out the script folder
import ai
import nt_config

HERE = Path(__file__).resolve().parent
TOKEN = secrets.token_urlsafe(16)


def state():
    cfg = nt_config.load()
    safe = {k: v for k, v in cfg.items() if k != "api_keys"}
    safe["has_key"] = {p: bool(k) for p, k in (cfg.get("api_keys") or {}).items()}
    safe["first_run"] = not nt_config.configured()
    return {**nt_config.detect(), "config": safe}


def models(body):
    cfg = nt_config.load()
    key = body.get("key") or (cfg.get("api_keys") or {}).get(body["provider"], "")
    return {"models": ai.list_models(body["provider"], key, body.get("ollama_url") or cfg["ollama_url"])}


def merged(body):
    cfg = nt_config.load()
    cfg["provider"] = body["provider"]
    cfg["model"] = body.get("model", "")
    cfg["ollama_url"] = body.get("ollama_url") or cfg["ollama_url"]
    if body.get("key"):
        cfg.setdefault("api_keys", {})[body["provider"]] = body["key"].strip()
    if body.get("library"):
        cfg["library"] = str(Path(body["library"]).expanduser())
    if "routes" in body:
        cfg["routes"] = body["routes"]
    if "screenshots" in body:
        cfg["screenshots"] = bool(body["screenshots"])
    return cfg


def test(body):
    cfg = merged(body)
    tmp = Path(nt_config.CONFIG).parent / "test"
    tmp.mkdir(parents=True, exist_ok=True)
    text = ai.generate(cfg, "Reply with the single word READY.", tmp)
    return {"reply": text.strip()[:80]}


def save(body):
    cfg = merged(body)
    lib = Path(cfg["library"])
    (lib / cfg["route_dir"]).mkdir(parents=True, exist_ok=True)
    nt_config.save(cfg)
    linked = [r["id"] for r in cfg["routes"] if nt_config.link_destination(cfg, r)]
    told = [nt_config.HOMES[h]["label"] for h in body.get("link_memories", []) if h in nt_config.HOMES
            and nt_config.link_memory(cfg, h)]
    threading.Timer(1.5, SERVER.shutdown).start()
    return {"saved": str(nt_config.CONFIG), "linked": linked, "told": told}


ROUTES = {"/api/state": lambda b: state(), "/api/models": models, "/api/test": test, "/api/save": save}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == f"/?t={TOKEN}":
            html = (HERE / "settings.html").read_text(encoding="utf-8").replace("__TOKEN__", TOKEN)
            return self.send(200, html.encode("utf-8"), "text/html; charset=utf-8")
        self.send(404, {"error": "Not found"})

    def do_POST(self):
        if self.headers.get("x-token") != TOKEN or self.path not in ROUTES:
            return self.send(403, {"error": "Forbidden"})
        n = int(self.headers.get("content-length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        try:
            self.send(200, ROUTES[self.path](body))
        except ai.AIError as e:
            self.send(400, {"error": str(e)})
        except Exception as e:  # noqa: BLE001 - shown on the page
            self.send(500, {"error": f"{type(e).__name__}: {e}"})


SERVER = ThreadingHTTPServer(("127.0.0.1", 0), Handler)

if __name__ == "__main__":
    url = f"http://127.0.0.1:{SERVER.server_address[1]}/?t={TOKEN}"
    print(url, flush=True)
    webbrowser.open(url)
    threading.Timer(1800, SERVER.shutdown).start()
    SERVER.serve_forever()
