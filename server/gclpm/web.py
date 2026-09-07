"""The HTTP side.

Serves the SAME dashboard page and the SAME JSON contract as the Windows tool,
which is the whole reason the contract was versioned in the first place: moving
the engine here must not change anything on anybody's phone.

`static/dashboard.html` is extracted verbatim from the .ps1; tools/check-page-sync
fails if the two ever drift.
"""

from __future__ import annotations

import logging
import time
from pathlib import Path

from aiohttp import web

from . import editor
from .state import Monitor, fmt_duration

log = logging.getLogger("gclpm.web")

STATIC = Path(__file__).parent / "static"
CONTRACT_VERSION = 1

# Where the link to the host editor is spliced into the dashboard.
#
# The dashboard page itself is byte-identical to the copy embedded in
# GCL-PingMonitor.ps1 and a test enforces that, because the phone must see the
# same UI whichever engine is answering. The editor is a server-only feature -
# the Windows tool has its own host list in a WinForms dialog - so its link is
# added here at serve time instead of being written into the shared page.
EDIT_ANCHOR = '<span id="fmon"></span>'
EDIT_LINK = '<a href="/hosts" style="color:#3b82f6">Edit hosts</a>'

MANIFEST = (
    '{{"name":"GCL Ping Monitor","short_name":"Ping Mon","start_url":"/?t={token}",'
    '"scope":"/","display":"standalone","background_color":"#0f1115",'
    '"theme_color":"#0f1115","icons":[{{"src":"/icon.svg","sizes":"any",'
    '"type":"image/svg+xml","purpose":"any maskable"}}]}}'
)

ICON = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192">'
    '<rect width="192" height="192" rx="34" fill="#0f1115"/>'
    '<circle cx="96" cy="96" r="52" fill="none" stroke="#22c55e" stroke-width="12"/>'
    '<circle cx="96" cy="96" r="20" fill="#22c55e"/></svg>'
)

DENIED = (
    '<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">'
    '<body style="font:16px system-ui;background:#111;color:#ddd;padding:2em">'
    "<h2>GCL Ping Monitor</h2><p>Access token required.</p></body>"
)


class Server:
    def __init__(self, monitor: Monitor, cfg, token: str, version: str, on_ack=None):
        self.mon = monitor
        self.cfg = cfg
        self.token = token
        self.version = version
        self.on_ack = on_ack
        self.page = (STATIC / "dashboard.html").read_text(encoding="utf-8")
        self.hosts_page = (STATIC / "hosts.html").read_text(encoding="utf-8")
        if self.can_edit:
            self.page = self.page.replace(EDIT_ANCHOR, EDIT_LINK + EDIT_ANCHOR, 1)

    @property
    def can_edit(self) -> bool:
        """Editing needs somewhere to write. When the config was built in memory
        - which is what the tests do - there is no file, so the editor is off
        rather than pretending to save."""
        return bool(self.cfg.web.get("allow_edit", True)) and self.cfg.path is not None

    # ---- auth ----------------------------------------------------------
    def _authorised(self, request: web.Request) -> bool:
        if not self.token:
            return True
        got = (request.query.get("t")
               or request.headers.get("X-Token")
               or request.cookies.get("gclpm")
               or "")
        return got == self.token

    def _guard(self, handler):
        async def wrapped(request: web.Request) -> web.StreamResponse:
            if not self._authorised(request):
                return web.Response(status=401, text=DENIED,
                                    content_type="text/html", charset="utf-8")
            return await handler(request)
        return wrapped

    # ---- the contract --------------------------------------------------
    def snapshot(self) -> dict:
        now = time.time()
        hosts = []
        for h in self.mon.all():
            hosts.append({
                "label": h.label,
                "target": h.target,
                "status": "OFF" if not h.enabled else h.status,
                "enabled": h.enabled,
                "sound": h.sound,
                "acked": h.acked,
                "rtt": int(round(h.latency)) if h.latency is not None else None,
                "loss": h.loss_percent,
                "since": time.strftime("%H:%M:%S", time.localtime(h.last_change)) if h.last_change else "",
                "downFor": fmt_duration(now - h.down_since) if (h.status == "DOWN" and h.down_since) else "",
            })
        active = self.mon.active()
        return {
            "v": CONTRACT_VERSION,
            "ready": True,
            "monitor": self.cfg.monitor_name,
            "version": self.version,
            "time": time.strftime("%H:%M:%S"),
            "checked": time.strftime("%H:%M:%S", time.localtime(self.mon.last_check)) if self.mon.last_check else "",
            "paused": self.mon.paused,
            "canAck": bool(self.cfg.web["allow_ack"]),
            "alarm": {
                "active": self.mon.alarm_active,
                "loud": self.mon.alarm_loud,
                # the desk tool auto-silences after N minutes; there is no
                # speaker here, so nothing is ever muted server-side
                "muted": False,
            },
            "counts": {
                "total": len(self.mon.all()),
                "up": sum(1 for h in active if h.status == "UP"),
                "down": sum(1 for h in active if h.status == "DOWN"),
                "off": len(self.mon.all()) - len(active),
            },
            "hosts": hosts,
            "log": list(self.mon.log),
        }

    # ---- handlers ------------------------------------------------------
    async def h_index(self, request: web.Request) -> web.StreamResponse:
        resp = web.Response(text=self.page, content_type="text/html", charset="utf-8")
        resp.headers["Cache-Control"] = "no-store"
        resp.headers["X-Content-Type-Options"] = "nosniff"
        if request.query.get("t"):
            # move the token out of the URL on first visit so a screenshot or a
            # shoulder-surfer does not hand it over
            resp.set_cookie("gclpm", self.token, max_age=31536000,
                            httponly=True, samesite="Lax", path="/")
        return resp

    async def h_status(self, request: web.Request) -> web.StreamResponse:
        resp = web.json_response(self.snapshot())
        resp.headers["Cache-Control"] = "no-store"
        return resp

    async def h_ack(self, request: web.Request) -> web.StreamResponse:
        if not self.cfg.web["allow_ack"]:
            return web.json_response({"ok": False, "error": "read-only"}, status=403)
        n = self.mon.acknowledge_all()
        if n:
            self.mon.note(f"ACK       : {n} host(s) acknowledged from a browser")
            if self.on_ack:
                self.on_ack()
        return web.json_response({"ok": True, "acknowledged": n})

    async def h_pause(self, request: web.Request) -> web.StreamResponse:
        self.mon.paused = True
        self.mon.note("MONITOR   : paused from a browser")
        return web.json_response({"ok": True})

    async def h_resume(self, request: web.Request) -> web.StreamResponse:
        self.mon.paused = False
        self.mon.note("MONITOR   : resumed from a browser")
        return web.json_response({"ok": True})

    # ---- the host editor -----------------------------------------------
    def _edit_guard(self) -> web.Response | None:
        if not self.can_edit:
            return web.json_response(
                {"ok": False, "error": "editing is disabled on this monitor"},
                status=403)
        return None

    async def h_hosts_page(self, request: web.Request) -> web.StreamResponse:
        if not self.can_edit:
            raise web.HTTPNotFound()
        resp = web.Response(text=self.hosts_page, content_type="text/html", charset="utf-8")
        resp.headers["Cache-Control"] = "no-store"
        resp.headers["X-Content-Type-Options"] = "nosniff"
        if request.query.get("t"):
            resp.set_cookie("gclpm", self.token, max_age=31536000,
                            httponly=True, samesite="Lax", path="/")
        return resp

    async def h_hosts_get(self, request: web.Request) -> web.StreamResponse:
        denied = self._edit_guard()
        if denied:
            return denied
        return web.json_response({"ok": True, "hosts": editor.read_hosts(self.cfg.path)})

    async def h_hosts_post(self, request: web.Request) -> web.StreamResponse:
        denied = self._edit_guard()
        if denied:
            return denied
        try:
            body = await request.json()
        except Exception:                              # noqa: BLE001
            return web.json_response({"ok": False, "error": "malformed request"}, status=400)

        try:
            hosts = editor.save_hosts(self.cfg.path, body.get("hosts"))
        except editor.ValidationError as exc:
            # 400, not 500: the person editing can fix this, and the page shows
            # the message next to the row it names
            return web.json_response({"ok": False, "error": str(exc)}, status=400)
        except Exception as exc:                       # noqa: BLE001
            log.exception("saving the host list failed")
            return web.json_response({"ok": False, "error": f"could not save: {exc}"},
                                     status=500)

        on, off = sum(1 for h in hosts if h["enabled"]), sum(1 for h in hosts if not h["enabled"])
        self.mon.note(f"CONFIG    : host list saved from a browser - "
                      f"{len(hosts)} host(s), {on} watched, {off} not")
        return web.json_response({"ok": True, "hosts": hosts})

    async def h_manifest(self, request: web.Request) -> web.StreamResponse:
        return web.Response(text=MANIFEST.format(token=self.token),
                            content_type="application/manifest+json", charset="utf-8")

    async def h_icon(self, request: web.Request) -> web.StreamResponse:
        return web.Response(text=ICON, content_type="image/svg+xml", charset="utf-8")

    async def h_sw(self, request: web.Request) -> web.StreamResponse:
        # deliberately a no-op: it exists only so Android offers "Install app".
        # Caching a monitoring page would be actively harmful.
        return web.Response(text="self.addEventListener('fetch',function(){});",
                            content_type="application/javascript", charset="utf-8")

    async def h_health(self, request: web.Request) -> web.StreamResponse:
        """Unauthenticated on purpose - it is what the container healthcheck and
        any external watchdog call, and it reveals nothing but liveness."""
        stale = (self.mon.last_check is None
                 or (time.time() - self.mon.last_check) > max(60.0, self.cfg.interval * 6))
        return web.json_response(
            {"healthy": not stale, "lastCheck": self.mon.last_check},
            status=200 if not stale else 503,
        )

    def build(self) -> web.Application:
        app = web.Application()
        app.add_routes([
            web.get("/", self._guard(self.h_index)),
            web.get("/api/status", self._guard(self.h_status)),
            web.post("/api/ack", self._guard(self.h_ack)),
            web.post("/api/pause", self._guard(self.h_pause)),
            web.post("/api/resume", self._guard(self.h_resume)),
            web.get("/hosts", self._guard(self.h_hosts_page)),
            web.get("/api/hosts", self._guard(self.h_hosts_get)),
            web.post("/api/hosts", self._guard(self.h_hosts_post)),
            web.get("/manifest.webmanifest", self._guard(self.h_manifest)),
            web.get("/icon.svg", self._guard(self.h_icon)),
            web.get("/sw.js", self._guard(self.h_sw)),
            web.get("/healthz", self.h_health),
        ])
        return app
