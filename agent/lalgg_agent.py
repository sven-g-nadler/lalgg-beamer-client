#!/usr/bin/env python3
"""lalgg-agent: the small, outbound-only management agent of the lal.gg beamer client.

Two jobs:

1. Local: serve http://127.0.0.1:8484/info so the lal.gg web page running in the kiosk
   browser can tell it is on a managed device (pairing code, fingerprint, hardware).
   Also accept POST /enroll from that page once the lal.gg pairing flow hands out a token.

2. Cloud: when enrolled, send a heartbeat to Directus every POLL_SECONDS, pick up a
   pending command (reboot, restart-browser, update, console), execute it, report back.

Python 3.11+ standard library only. Runs as root (systemd). Nothing listens on any
interface except loopback. See docs/device-api.md for the (proposed) server side.
"""
import hashlib
import json
import os
import platform
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = "/etc/lalgg-beamer/config.env"
LIB_DIR = "/usr/local/lib/lalgg-beamer"
STATE_DIR = "/var/lib/lalgg-beamer"
LISTEN = ("127.0.0.1", 8484)

# ----------------------------------------------------------------------------- config

def load_conf():
    conf = {}
    try:
        with open(CONF, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    conf[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    conf.setdefault("MANAGE_URL", "https://manage.lal.gg")
    conf.setdefault("DIRECTUS_URL", "https://directus.lockandload.ch")
    conf.setdefault("POLL_SECONDS", "30")
    return conf


def save_conf_keys(**updates):
    """Rewrite only the given keys in config.env (keeps comments and order)."""
    lines = []
    seen = set()
    if os.path.exists(CONF):
        with open(CONF, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    out = []
    for line in lines:
        m = re.match(r"^([A-Z0-9_]+)=", line)
        if m and m.group(1) in updates:
            out.append(f"{m.group(1)}={updates[m.group(1)]}")
            seen.add(m.group(1))
        else:
            out.append(line)
    for k, v in updates.items():
        if k not in seen:
            out.append(f"{k}={v}")
    tmp = CONF + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONF)

# ----------------------------------------------------------------------------- hardware

def _read(path, default=""):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return default


def _run(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def fingerprint():
    """Stable per-box id: machine-id + DMI product UUID (or serial), 16 hex chars."""
    raw = _read("/etc/machine-id") + "|" + (_read("/sys/class/dmi/id/product_uuid")
                                             or _read("/sys/class/dmi/id/product_serial")
                                             or _read("/proc/cpuinfo"))
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def pairing_code(fp):
    """Human-friendly code shown on screen; derived, so it survives reboots. 6 chars,
    no 0/O/1/I. The pairing *secret* (random, in state dir) is what actually proves
    the claim - see docs/device-api.md."""
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    n = int(hashlib.sha256(("pair|" + fp).encode()).hexdigest(), 16)
    return "".join(alphabet[(n >> (5 * i)) % len(alphabet)] for i in range(6))


def pairing_secret():
    path = os.path.join(STATE_DIR, "pairing_secret")
    s = _read(path)
    if not s:
        s = secrets.token_urlsafe(24)
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(s)
        os.chmod(path, 0o600)
    return s


def displays():
    out = []
    base = "/sys/class/drm"
    try:
        for name in sorted(os.listdir(base)):
            p = os.path.join(base, name)
            if os.path.exists(os.path.join(p, "status")):
                out.append({
                    "connector": re.sub(r"^card\d+-", "", name),
                    "status": _read(os.path.join(p, "status")),
                    "enabled": _read(os.path.join(p, "enabled")),
                    "modes": _read(os.path.join(p, "modes")).splitlines()[:5],
                })
    except OSError:
        pass
    return out


def ip_addresses():
    ips = []
    for line in _run(["ip", "-br", "-4", "addr"]).splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] != "lo" and parts[1] == "UP":
            ips.append({"iface": parts[0], "ip": parts[2].split("/")[0]})
    return ips


def hardware():
    mem_kb = 0
    for line in _read("/proc/meminfo").splitlines():
        if line.startswith("MemTotal"):
            mem_kb = int(line.split()[1])
    # x86 lists a numeric "model : 140" before "model name"; Pi has "model name" per core
    # (armv7) or only a trailing "Model : Raspberry Pi 4 ..." line (arm64). Prefer the name.
    cpu = ""
    for line in _read("/proc/cpuinfo").splitlines():
        key, _, val = line.partition(":")
        key = key.strip().lower()
        if key == "model name":
            cpu = val.strip()
            break
        if key == "model" and not val.strip().isdigit():
            cpu = val.strip()
    temp = _read("/sys/class/thermal/thermal_zone0/temp")
    # x86: DMI/SMBIOS via sysfs (root-readable). Raspberry Pi: device tree instead.
    dt_model = _read("/proc/device-tree/model").replace("\x00", "")
    dt_serial = _read("/proc/device-tree/serial-number").replace("\x00", "")
    return {
        "vendor": _read("/sys/class/dmi/id/sys_vendor") or ("Raspberry Pi" if dt_model else ""),
        "product": _read("/sys/class/dmi/id/product_name") or dt_model,
        "serial": _read("/sys/class/dmi/id/product_serial") or dt_serial,
        "bios": _read("/sys/class/dmi/id/bios_version"),
        "cpu": cpu,
        "memory_mb": mem_kb // 1024,
        "arch": platform.machine(),
        "kernel": platform.release(),
        "temperature_c": round(int(temp) / 1000, 1) if temp.isdigit() else None,
        "uptime_s": int(float(_read("/proc/uptime", "0 0").split()[0])),
        "displays": displays(),
        "ips": ip_addresses(),
    }


def agent_version():
    return _read(os.path.join(LIB_DIR, "VERSION"), "dev")

# ----------------------------------------------------------------------------- info doc

def info(conf):
    fp = fingerprint()
    enrolled = bool(conf.get("DEVICE_TOKEN")) and bool(conf.get("DEVICE_ID"))
    doc = {
        "agent": "lalgg-beamer-client",
        "version": agent_version(),
        "fingerprint": fp,
        "hostname": socket.gethostname(),
        "enrolled": enrolled,
        "device_id": conf.get("DEVICE_ID") or None,
        "manage_url": conf["MANAGE_URL"],
        "directus_url": conf["DIRECTUS_URL"],
        "capabilities": ["reboot", "restart-browser", "update", "displays", "console"],
        "hardware": hardware(),
        # Non-secret settings for start-kiosk.sh, which runs as 'kiosk' and must not read
        # config.env (it holds DEVICE_TOKEN). Fetched from localhost at every session start.
        "kiosk": {
            "start_url": conf.get("KIOSK_START_URL") or conf["MANAGE_URL"].rstrip("/") + "/beamer/device",
            "extra_flags": conf.get("KIOSK_EXTRA_FLAGS", ""),
            "allow_vt_switch": conf.get("KIOSK_ALLOW_VT_SWITCH", "1") == "1",
        },
    }
    if not enrolled:
        doc["pairing"] = {"code": pairing_code(fp), "secret": pairing_secret()}
    return doc

# ----------------------------------------------------------------------------- commands

def restart_browser():
    subprocess.run(["pkill", "-u", "kiosk", "cage"], check=False)
    return "browser restarted"


def run_command(name):
    if name == "reboot":
        threading.Timer(2.0, lambda: subprocess.run(["systemctl", "reboot"], check=False)).start()
        return "rebooting"
    if name == "restart-browser":
        return restart_browser()
    if name == "update":
        r = subprocess.run([os.path.join(LIB_DIR, "update.sh")], capture_output=True, text=True, timeout=600)
        return (r.stdout + r.stderr)[-2000:] or f"exit {r.returncode}"
    if name == "console":
        subprocess.run(["chvt", "2"], check=False)
        return "switched to console"
    return f"unknown command: {name}"

# ----------------------------------------------------------------------------- directus

def directus(conf, method, path, body=None):
    url = conf["DIRECTUS_URL"].rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + conf["DEVICE_TOKEN"])
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "lalgg-beamer-client/" + agent_version())
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def cloud_loop():
    """Heartbeat + command pickup. Field names follow docs/device-api.md."""
    backoff = 5
    while True:
        conf = load_conf()
        if not (conf.get("DEVICE_TOKEN") and conf.get("DEVICE_ID")):
            time.sleep(10)
            continue
        try:
            hw = hardware()
            patch = {
                "last_seen": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "agent_version": agent_version(),
                "hostname": socket.gethostname(),
                "hardware": hw,
                "ip_address": (hw["ips"][0]["ip"] if hw["ips"] else None),
                "uptime_s": hw["uptime_s"],
                "temperature_c": hw["temperature_c"],
            }
            resp = directus(conf, "PATCH", f"/items/beamer_devices/{conf['DEVICE_ID']}"
                            "?fields=pending_command,assigned_playlist,manage_url", patch)
            data = resp.get("data", {})
            cmd = data.get("pending_command")
            if cmd:
                result = run_command(cmd)
                directus(conf, "PATCH", f"/items/beamer_devices/{conf['DEVICE_ID']}",
                         {"pending_command": None,
                          "last_command": cmd,
                          "last_command_result": result,
                          "last_command_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
            new_url = data.get("manage_url")
            if new_url and new_url != conf["MANAGE_URL"]:
                save_conf_keys(MANAGE_URL=new_url)
                restart_browser()
            backoff = 5
        except urllib.error.HTTPError as e:
            log(f"directus {e.code} {e.reason}")
            if e.code in (401, 403):
                log("token rejected - device may have been revoked; staying idle")
                time.sleep(300)
                continue
            backoff = min(backoff * 2, 300)
            time.sleep(backoff)
            continue
        except (urllib.error.URLError, OSError, ValueError) as e:
            log(f"network: {e}")
            backoff = min(backoff * 2, 300)
            time.sleep(backoff)
            continue
        time.sleep(int(conf["POLL_SECONDS"]))

# ----------------------------------------------------------------------------- local http

class Handler(BaseHTTPRequestHandler):
    server_version = "lalgg-agent"

    def _cors(self):
        origin = self.headers.get("Origin", "")
        conf = load_conf()
        allowed = {conf["MANAGE_URL"].rstrip("/"), "https://lal.gg", "http://localhost:5173"}
        if origin in allowed:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, code, doc):
        body = json.dumps(doc).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path.split("?")[0] == "/info":
            return self._json(200, info(load_conf()))
        self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self._json(400, {"error": "bad json"})
        path = self.path.split("?")[0]
        if path == "/enroll":
            # Called by the lal.gg page after an Org Admin claimed the pairing code.
            # The page must present the pairing secret it read from /info, so only the
            # page running on *this* box can enroll it.
            if body.get("pairing_secret") != pairing_secret():
                return self._json(403, {"error": "bad pairing secret"})
            for k in ("device_id", "device_token"):
                if not body.get(k):
                    return self._json(400, {"error": f"missing {k}"})
            save_conf_keys(DEVICE_ID=body["device_id"], DEVICE_TOKEN=body["device_token"],
                           DIRECTUS_URL=body.get("directus_url", load_conf()["DIRECTUS_URL"]))
            try:
                os.remove(os.path.join(STATE_DIR, "pairing_secret"))
            except OSError:
                pass
            log("enrolled as device " + body["device_id"])
            return self._json(200, {"ok": True})
        if path == "/command":
            # Local commands from the page (restart the browser, jump to console).
            # Only harmless, box-local actions; reboot/update come via Directus.
            cmd = body.get("command")
            if cmd not in ("restart-browser", "console"):
                return self._json(400, {"error": "not allowed locally"})
            return self._json(200, {"result": run_command(cmd)})
        self._json(404, {"error": "not found"})

    def log_message(self, fmt, *args):  # quiet
        pass


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    threading.Thread(target=cloud_loop, name="cloud", daemon=True).start()
    srv = ThreadingHTTPServer(LISTEN, Handler)
    log(f"listening on {LISTEN[0]}:{LISTEN[1]}, fingerprint {fingerprint()}, code {pairing_code(fingerprint())}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
