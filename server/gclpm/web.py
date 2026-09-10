"""The HTTP side.

Serves the SAME dashboard page and the SAME JSON contract as the Windows tool,
which is the whole reason the contract was versioned in the first place: moving
the engine here must not change anything on anybody's phone.

`static/dashboard.html` is extracted verbatim from the .ps1; tools/check-page-sync
fails if the two ever drift.
"""

from __future__ import annotations

import hmac
import logging
import time
from pathlib import Path
from urllib.parse import quote

from aiohttp import web

from . import config as cfgmod
from . import editor
from .auth import ROLES, AuthError, Sessions, User, Users
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
    def __init__(self, monitor: Monitor, cfg, token: str, version: str,
                 on_ack=None, users: Users | None = None):
        self.mon = monitor
        self.cfg = cfg
        self.token = token
        self.version = version
        self.on_ack = on_ack
        self.users = users if users is not None else Users(None)
        self.sessions = Sessions(cfg.web.get("session_hours", 12)
                                 if hasattr(cfg, "web") else 12)
        self.page = (STATIC / "dashboard.html").read_text(encoding="utf-8")
        self.hosts_page = (STATIC / "hosts.html").read_text(encoding="utf-8")
        self.login_page = (STATIC / "login.html").read_text(encoding="utf-8")
        self.users_page = (STATIC / "users.html").read_text(encoding="utf-8")
        if self.can_edit:
            self.page = self.page.replace(EDIT_ANCHOR, EDIT_LINK + EDIT_ANCHOR, 1)

    @property
    def can_edit(self) -> bool:
        """Editing needs somewhere to write. When the config was built in memory
        - which is what the tests do - there is no file, so the editor is off
        rather than pretending to save."""
        return bool(self.cfg.web.get("allow_edit", True)) and self.cfg.path is not None

    @property
    def link_role(self) -> str:
        """What the shared notification link is worth.

        Only consulted once real users exist. Until then the link is the only
        lock there is, and demoting it would lock the operator out of their
        own dashboard on the strength of an upgrade they did not ask for.
        """
        if not self.users.enabled:
            return "admin"
        role = str(self.cfg.web.get("link_role", "read")).strip().lower()
        return role if role in ("read", "write", "admin") else "read"

    # ---- auth ----------------------------------------------------------
    def user_for(self, request: web.Request) -> User | None:
        """Who is asking, or None. A session beats the shared link."""
        self.users.reload()
        who = self.sessions.user_of(request.cookies.get("gclpm_s", ""), self.users)
        if who is not None:
            return who
        got = (request.query.get("t")
               or request.headers.get("X-Token")
               or request.cookies.get("gclpm")
               or "")
        if self.token:
            return User("link", self.link_role) if hmac.compare_digest(got, self.token) else None
        # No token and no users: an unlocked monitor, which is what the tests
        # and a first run on a private LAN look like.
        return None if self.users.enabled else User("", "admin")

    def _guard(self, handler, need: str = "read"):
        async def wrapped(request: web.Request) -> web.StreamResponse:
            who = self.user_for(request)
            if who is None:
                wants_html = "text/html" in request.headers.get("Accept", "")
                if wants_html and self.users.enabled:
                    # come back to the page they actually wanted
                    raise web.HTTPFound(
                        "/login?next=" + quote(request.path, safe="/"))
                return web.Response(status=401, text=DENIED,
                                    content_type="text/html", charset="utf-8")
            if not who.can(need):
                # 403, not 401: signing in again will not help, and saying so
                # is kinder than a login form that rejects a correct password.
                return web.json_response(
                    {"ok": False,
                     "error": f"your account is {who.role}; this needs {need}"},
                    status=403)
            request["who"] = who
            return await handler(request)
        return wrapped

    # ---- the contract --------------------------------------------------
    def snapshot(self, who: User | None = None) -> dict:
        now = time.time()
        hosts = []
        for h in self.mon.all():
            hosts.append({
                "label": h.label,
                "target": h.target,
                "group": h.group,
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
            # What THIS caller may do, so the page can hide a button rather
            # than offer one that will 403. The server checks again anyway -
            # a hidden button is a courtesy, never a control.
            "canAck": bool(self.cfg.web["allow_ack"]) and (who is None or who.can("write")),
            "canEdit": self.can_edit and (who is None or who.can("write")),
            "you": {
                "name": who.name if who else "",
                "role": who.role if who else "admin",
                "auth": self.users.enabled,
            },
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
            "groups": self._groups(),
            "hosts": hosts,
            "log": list(self.mon.log),
        }

    def _groups(self) -> list[dict]:
        """The layers in hierarchy order, each with its own tally.

        Counted here rather than in the page so that the numbers on a group
        heading come from the same pass as the numbers in the banner. Two
        places counting the same hosts is two places to disagree, and a
        heading that says "12 up" over a red row is worse than no heading.
        """
        by_name: dict[str, dict] = {}
        for name in self.cfg.groups:
            by_name[name] = {"name": name, "total": 0, "up": 0,
                             "down": 0, "warn": 0, "off": 0}
        for h in self.mon.all():
            g = by_name.get(h.group or cfgmod.UNGROUPED)
            if g is None:                      # a group added since the reload
                continue
            g["total"] += 1
            if not h.enabled:
                g["off"] += 1
            elif h.status == "DOWN":
                g["down"] += 1
            elif h.status == "WARN":
                g["warn"] += 1
            elif h.status == "UP":
                g["up"] += 1
        return list(by_name.values())

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
        resp = web.json_response(self.snapshot(request.get("who")))
        resp.headers["Cache-Control"] = "no-store"
        return resp

    # ---- signing in ----------------------------------------------------
    def _set_session(self, resp: web.StreamResponse, token: str) -> None:
        resp.set_cookie("gclpm_s", token, max_age=int(self.sessions.ttl),
                        httponly=True, samesite="Lax", path="/",
                        secure=bool(self.cfg.web.get("https_only", False)))

    async def h_login_page(self, request: web.Request) -> web.StreamResponse:
        resp = web.Response(text=self.login_page, content_type="text/html",
                            charset="utf-8")
        resp.headers["Cache-Control"] = "no-store"
        resp.headers["X-Content-Type-Options"] = "nosniff"
        return resp

    async def h_login(self, request: web.Request) -> web.StreamResponse:
        if not self.users.enabled:
            return web.json_response(
                {"ok": False, "error": "no users are configured on this monitor"},
                status=400)
        try:
            body = await request.json()
        except Exception:                                    # noqa: BLE001
            return web.json_response({"ok": False, "error": "malformed request"},
                                     status=400)
        try:
            who = self.users.check(body.get("username"), body.get("password"))
        except AuthError as exc:
            # One message for a bad name and a bad password, and the same
            # delay, so the form cannot be used to enumerate accounts.
            return web.json_response({"ok": False, "error": str(exc)}, status=401)

        resp = web.json_response({"ok": True, "you": who.public()})
        self._set_session(resp, self.sessions.new(who))
        self.mon.note(f"LOGIN     : {who.name} signed in ({who.role})")
        return resp

    async def h_logout(self, request: web.Request) -> web.StreamResponse:
        self.sessions.drop(request.cookies.get("gclpm_s", ""))
        resp = web.json_response({"ok": True})
        resp.del_cookie("gclpm_s", path="/")
        # The shared link would otherwise sign them straight back in, which
        # is not what anybody means by "log out".
        resp.del_cookie("gclpm", path="/")
        return resp

    async def h_me(self, request: web.Request) -> web.StreamResponse:
        who = request["who"]
        return web.json_response({"ok": True, "you": who.public(),
                                  "auth": self.users.enabled,
                                  "canEdit": self.can_edit})

    # ---- the user list (admin only) ------------------------------------
    async def h_users_page(self, request: web.Request) -> web.StreamResponse:
        resp = web.Response(text=self.users_page, content_type="text/html",
                            charset="utf-8")
        resp.headers["Cache-Control"] = "no-store"
        resp.headers["X-Content-Type-Options"] = "nosniff"
        return resp

    async def h_users_get(self, request: web.Request) -> web.StreamResponse:
        return web.json_response({"ok": True, "users": self.users.list(),
                                  "roles": list(ROLES)})

    async def h_users_post(self, request: web.Request) -> web.StreamResponse:
        try:
            body = await request.json()
        except Exception:                                    # noqa: BLE001
            return web.json_response({"ok": False, "error": "malformed request"},
                                     status=400)
        actor = request["who"]
        action = str(body.get("action", "save"))
        try:
            if action == "remove":
                name = str(body.get("name", "")).strip().lower()
                if name == actor.name:
                    raise AuthError("you cannot remove the account you are using")
                self.users.remove(name, actor=actor.name)
                self.sessions.drop_user(name)
            else:
                user = self.users.upsert(body.get("name"), body.get("role"),
                                         body.get("password"), actor=actor.name)
                # A demotion or a new password must not leave an old session
                # running at the old level.
                if user.name != actor.name:
                    self.sessions.drop_user(user.name)
        except AuthError as exc:
            return web.json_response({"ok": False, "error": str(exc)}, status=400)
        except Exception as exc:                             # noqa: BLE001
            log.exception("saving the user list failed")
            return web.json_response({"ok": False, "error": f"could not save: {exc}"},
                                     status=500)
        self.mon.note(f"USERS     : {action} by {actor.name}")
        return web.json_response({"ok": True, "users": self.users.list()})

    async def h_ack(self, request: web.Request) -> web.StreamResponse:
        if not self.cfg.web["allow_ack"]:
            return web.json_response({"ok": False, "error": "read-only"}, status=403)
        n = self.mon.acknowledge_all()
        if n:
            who = request.get("who")
            by = f" by {who.name}" if who and who.name else ""
            self.mon.note(f"ACK       : {n} host(s) acknowledged from a browser{by}")
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
        return web.json_response({"ok": True,
                                  "hosts": editor.read_hosts(self.cfg.path),
                                  "groups": editor.read_groups(self.cfg.path)})

    async def h_hosts_post(self, request: web.Request) -> web.StreamResponse:
        denied = self._edit_guard()
        if denied:
            return denied
        try:
            body = await request.json()
        except Exception:                              # noqa: BLE001
            return web.json_response({"ok": False, "error": "malformed request"}, status=400)

        try:
            hosts, groups = editor.save_hosts(self.cfg.path, body.get("hosts"),
                                              body.get("groups"))
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
        return web.json_response({"ok": True, "hosts": hosts, "groups": groups})

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
            # read: looking at it
            web.get("/", self._guard(self.h_index)),
            web.get("/api/status", self._guard(self.h_status)),
            web.get("/api/me", self._guard(self.h_me)),
            web.get("/manifest.webmanifest", self._guard(self.h_manifest)),
            web.get("/icon.svg", self._guard(self.h_icon)),
            web.get("/sw.js", self._guard(self.h_sw)),

            # write: changing what is monitored, or silencing it
            web.post("/api/ack", self._guard(self.h_ack, "write")),
            web.post("/api/pause", self._guard(self.h_pause, "write")),
            web.post("/api/resume", self._guard(self.h_resume, "write")),
            web.get("/hosts", self._guard(self.h_hosts_page, "write")),
            web.get("/api/hosts", self._guard(self.h_hosts_get, "write")),
            web.post("/api/hosts", self._guard(self.h_hosts_post, "write")),

            # admin: who else gets in
            web.get("/users", self._guard(self.h_users_page, "admin")),
            web.get("/api/users", self._guard(self.h_users_get, "admin")),
            web.post("/api/users", self._guard(self.h_users_post, "admin")),

            # open on purpose: the way in, and the way a watchdog checks
            web.get("/login", self.h_login_page),
            web.post("/api/login", self.h_login),
            web.post("/api/logout", self.h_logout),
            web.get("/healthz", self.h_health),
        ])
        return app
