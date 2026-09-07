"""Notifications: batching, the hourly cap, and the repeat-while-down reminder.

The ntfy path is exercised against a real local HTTP server rather than a mock,
because the things that go wrong with it are wire-level - header encoding,
priority, and the UTF-8 body.
"""

import asyncio
import time

import pytest
from aiohttp import web

from gclpm import config as cfgmod
from gclpm.config import HostSpec
from gclpm.notify import Notifier
from gclpm.state import Monitor


def build_cfg(**notify_over):
    notify = cfgmod._merge(cfgmod.DEFAULTS["notify"], notify_over)
    raw = cfgmod._merge(cfgmod.DEFAULTS, {"notify": notify})
    return cfgmod.Config(raw=raw, secrets={})


def make_notifier(cfg):
    lines = []
    n = Notifier(cfg, "TESTBOX", lines.append)
    return n, lines


def down_host(label="RTR", target="10.0.0.1", minutes=7):
    mon = Monitor()
    mon.sync([HostSpec(label, target)], 100)
    h = mon.hosts[target]
    mon.record(h, None, 1)
    h.down_since = time.time() - minutes * 60
    return mon, h


# ---- a fake ntfy ---------------------------------------------------------
@pytest.fixture
async def ntfy(aiohttp_server):
    seen = []

    async def handler(request: web.Request):
        seen.append({
            "path": request.path,
            "method": request.method,
            "headers": dict(request.headers),
            "body": await request.text(),
        })
        return web.json_response({"id": "fake"})

    app = web.Application()
    app.router.add_route("*", "/{tail:.*}", handler)
    server = await aiohttp_server(app)
    server.seen = seen
    return server


async def test_ntfy_down_alert_is_urgent(ntfy):
    cfg = build_cfg(ntfy={"enabled": True, "server": str(ntfy.make_url("")).rstrip("/"),
                          "topic": "gcl-test"})
    n, log = make_notifier(cfg)
    mon, host = down_host()
    n.add("DOWN", host)
    await n.flush()
    await n.close()

    assert len(ntfy.seen) == 1
    req = ntfy.seen[0]
    assert req["method"] == "POST" and req["path"] == "/gcl-test"
    assert req["headers"]["Priority"] == "5"
    assert "rotating_light" in req["headers"]["Tags"]
    assert "CRITICAL" not in req["headers"]["Title"], "the marker is redundant with priority"
    assert "RTR" in req["headers"]["Title"]
    assert "RTR" in req["body"] and "10.0.0.1" in req["body"]
    assert any("ntfy sent" in line for line in log)


async def test_ntfy_recovery_is_quieter(ntfy):
    cfg = build_cfg(ntfy={"enabled": True, "server": str(ntfy.make_url("")).rstrip("/"),
                          "topic": "gcl-test"})
    n, _ = make_notifier(cfg)
    mon, host = down_host()
    mon.record(host, 5.0, 1)
    n.add("UP", host)
    await n.flush()
    await n.close()
    # a recovery at priority 5 would wake someone at 3am to say all is well
    assert ntfy.seen[0]["headers"]["Priority"] == "3"


async def test_ntfy_title_is_ascii_but_body_keeps_utf8(ntfy):
    cfg = build_cfg(ntfy={"enabled": True, "server": str(ntfy.make_url("")).rstrip("/"),
                          "topic": "t"})
    n, _ = make_notifier(cfg)
    mon = Monitor()
    mon.sync([HostSpec("রাউটার ৬", "10.0.0.1")], 100)
    h = mon.hosts["10.0.0.1"]
    mon.record(h, None, 1)
    n.add("DOWN", h)
    await n.flush()
    await n.close()
    req = ntfy.seen[0]
    # ntfy reads headers as latin-1; the body is UTF-8 and must survive
    assert all(ord(c) < 128 for c in req["headers"]["Title"])
    assert "রাউটার" in req["body"]
    assert "\U0001F534" in req["body"], "the status emoji belongs in the body"


async def test_batching_collapses_many_events_into_one_message(ntfy):
    cfg = build_cfg(ntfy={"enabled": True, "server": str(ntfy.make_url("")).rstrip("/"),
                          "topic": "t"})
    n, _ = make_notifier(cfg)
    mon = Monitor()
    mon.sync([HostSpec(f"H{i}", f"10.0.0.{i}") for i in range(1, 6)], 100)
    for h in mon.all():
        mon.record(h, None, 1)
        n.add("DOWN", h)
    await n.flush()
    await n.close()
    assert len(ntfy.seen) == 1, "a link failure taking 5 hosts down is ONE message"
    assert "5 host(s) Down" in ntfy.seen[0]["headers"]["Title"]


async def test_hourly_cap(ntfy):
    cfg = build_cfg(max_per_hour=2,
                    ntfy={"enabled": True, "server": str(ntfy.make_url("")).rstrip("/"),
                          "topic": "t"})
    n, log = make_notifier(cfg)
    mon, host = down_host()
    for _ in range(4):
        n.add("DOWN", host)
        await n.flush()
    await n.close()
    assert len(ntfy.seen) == 2
    assert any("hourly limit" in line for line in log)


async def test_disabled_events_are_not_queued(ntfy):
    cfg = build_cfg(on_down=False,
                    ntfy={"enabled": True, "server": str(ntfy.make_url("")).rstrip("/"),
                          "topic": "t"})
    n, _ = make_notifier(cfg)
    mon, host = down_host()
    n.add("DOWN", host)
    await n.flush()
    await n.close()
    assert ntfy.seen == [], "on_down:false is why nothing was ever sent on the PC"


# ---- the repeat-while-down reminder --------------------------------------
async def test_reminder_waits_then_fires(ntfy):
    cfg = build_cfg(repeat_min=10,
                    ntfy={"enabled": True, "server": str(ntfy.make_url("")).rstrip("/"),
                          "topic": "t"})
    n, _ = make_notifier(cfg)
    mon, host = down_host(minutes=30)

    await n.reminder([host])
    assert ntfy.seen == [], "the first call only starts the clock"

    await n.reminder([host])
    assert ntfy.seen == [], "still inside the interval"

    n.last_sent = time.time() - 11 * 60
    await n.reminder([host])
    assert len(ntfy.seen) == 1
    assert "STILL DOWN" in ntfy.seen[0]["headers"]["Title"]
    assert "30m" in ntfy.seen[0]["body"], "how long it has been down is the useful bit"
    assert "until someone acknowledges" in ntfy.seen[0]["body"]
    await n.close()


async def test_reminder_stops_when_nothing_is_down(ntfy):
    cfg = build_cfg(repeat_min=10,
                    ntfy={"enabled": True, "server": str(ntfy.make_url("")).rstrip("/"),
                          "topic": "t"})
    n, _ = make_notifier(cfg)
    n.last_sent = time.time() - 60 * 60
    await n.reminder([])
    await n.close()
    assert ntfy.seen == []
    assert n.last_sent is None, "the clock resets, so the next outage waits its turn"


async def test_reminder_off_by_default(ntfy):
    cfg = build_cfg(ntfy={"enabled": True, "server": str(ntfy.make_url("")).rstrip("/"),
                          "topic": "t"})
    n, _ = make_notifier(cfg)
    mon, host = down_host()
    n.last_sent = time.time() - 60 * 60
    await n.reminder([host])
    await n.close()
    assert ntfy.seen == [], "repeat_min defaults to 0 = the old behaviour"


async def test_a_real_message_restarts_the_reminder_clock(ntfy):
    cfg = build_cfg(repeat_min=10,
                    ntfy={"enabled": True, "server": str(ntfy.make_url("")).rstrip("/"),
                          "topic": "t"})
    n, _ = make_notifier(cfg)
    mon, host = down_host()
    n.add("DOWN", host)
    await n.flush()
    before = len(ntfy.seen)
    await n.reminder([host])
    await n.close()
    assert len(ntfy.seen) == before, "no 'still down' seconds after the real alert"


async def test_one_bad_channel_does_not_stop_the_others(ntfy):
    # email points at a port nothing is listening on; ntfy must still go
    cfg = build_cfg(
        email={"enabled": True, "smtp_server": "127.0.0.1", "port": 9,
               "security": "none", "user": "", "sender": "a@b.c", "to": "d@e.f"},
        ntfy={"enabled": True, "server": str(ntfy.make_url("")).rstrip("/"), "topic": "t"},
    )
    n, log = make_notifier(cfg)
    mon, host = down_host()
    n.add("DOWN", host)
    await n.flush()
    await n.close()
    assert len(ntfy.seen) == 1, "a dead SMTP server must not swallow the phone alert"
    assert any("email" in line and "err" in line for line in log)
