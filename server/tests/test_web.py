"""The HTTP contract.

The point of these is that the phone and the browser must not be able to tell
whether the engine is the Windows tool or this one. Anything that changes the
shape of /api/status is a breaking change and should fail here.
"""

import json

import pytest
from aiohttp.test_utils import TestClient, TestServer

from gclpm import config as cfgmod
from gclpm.config import HostSpec
from gclpm.state import Monitor
from gclpm.web import CONTRACT_VERSION, Server

TOKEN = "testtoken123"


def build_cfg(**over):
    raw = cfgmod._merge(cfgmod.DEFAULTS, {"monitor_name": "TESTBOX", **over})
    return cfgmod.Config(raw=raw, secrets={})


@pytest.fixture
async def client(aiohttp_client):
    mon = Monitor()
    mon.sync([
        HostSpec("GOOGLE", "8.8.8.8", sound=False),
        HostSpec("RTR", "10.0.0.1"),
        HostSpec("OLD", "10.0.0.9", enabled=False),
    ], 100)
    mon.record(mon.hosts["8.8.8.8"], 22.0, 2)
    mon.record(mon.hosts["10.0.0.1"], None, 1)      # -> DOWN
    mon.note("TEST      : a log line")

    srv = Server(mon, build_cfg(), TOKEN, "1.0.0")
    cl = await aiohttp_client(srv.build())
    cl.monitor = mon
    cl.server_obj = srv
    return cl


async def test_no_token_is_refused(client):
    assert (await client.get("/api/status")).status == 401
    assert (await client.get("/")).status == 401
    assert (await client.get("/api/status", headers={"X-Token": "wrong"})).status == 401


async def test_health_needs_no_token(client):
    # the watchdog and the container healthcheck call this; it must not need a
    # secret, and it must not leak anything either
    r = await client.get("/healthz")
    body = await r.json()
    assert set(body) == {"healthy", "lastCheck"}


async def test_page_is_the_dashboard(client):
    r = await client.get(f"/?t={TOKEN}")
    assert r.status == 200
    text = await r.text()
    assert "GCL Ping Monitor" in text and "/api/status" in text
    assert "gclpm" in r.headers.get("Set-Cookie", ""), "the token should move to a cookie"


async def test_status_contract(client):
    r = await client.get("/api/status", headers={"X-Token": TOKEN})
    assert r.status == 200
    j = await r.json()

    assert j["v"] == CONTRACT_VERSION == 1
    for key in ("ready", "monitor", "version", "time", "checked", "paused",
                "canAck", "alarm", "counts", "hosts", "log"):
        assert key in j, f"the page reads {key}"
    assert set(j["alarm"]) == {"active", "loud", "muted"}
    assert set(j["counts"]) == {"total", "up", "down", "off"}

    host = j["hosts"][0]
    for key in ("label", "target", "status", "enabled", "sound", "acked",
                "rtt", "loss", "since", "downFor"):
        assert key in host, f"the page reads host.{key}"


async def test_counts_and_states(client):
    j = await (await client.get("/api/status", headers={"X-Token": TOKEN})).json()
    assert j["counts"] == {"total": 3, "up": 1, "down": 1, "off": 1}
    by = {h["label"]: h for h in j["hosts"]}
    assert by["GOOGLE"]["status"] == "UP" and by["GOOGLE"]["rtt"] == 22
    assert by["GOOGLE"]["sound"] is False
    assert by["RTR"]["status"] == "DOWN"
    assert by["OLD"]["status"] == "OFF", "a disabled host reports OFF, not its last state"


async def test_alarm_reflects_the_sound_switch(client):
    j = await (await client.get("/api/status", headers={"X-Token": TOKEN})).json()
    assert j["alarm"]["active"] is True and j["alarm"]["loud"] is True

    # silence the only down host: still an alarm, just not a loud one
    client.monitor.hosts["10.0.0.1"].sound = False
    j = await (await client.get("/api/status", headers={"X-Token": TOKEN})).json()
    assert j["alarm"]["active"] is True
    assert j["alarm"]["loud"] is False


async def test_token_never_appears_in_the_status_body(client):
    text = await (await client.get("/api/status", headers={"X-Token": TOKEN})).text()
    assert TOKEN not in text


async def test_ack(client):
    r = await client.post("/api/ack", headers={"X-Token": TOKEN})
    assert r.status == 200 and (await r.json())["acknowledged"] == 1
    j = await (await client.get("/api/status", headers={"X-Token": TOKEN})).json()
    assert j["alarm"]["active"] is False
    assert next(h for h in j["hosts"] if h["label"] == "RTR")["acked"] is True


async def test_ack_rejects_get(client):
    assert (await client.get("/api/ack", headers={"X-Token": TOKEN})).status == 405


async def test_read_only_mode_blocks_ack(aiohttp_client):
    mon = Monitor()
    mon.sync([HostSpec("A", "10.0.0.1")], 100)
    mon.record(mon.hosts["10.0.0.1"], None, 1)
    srv = Server(mon, build_cfg(web={"port": 8080, "allow_ack": False}), TOKEN, "1.0.0")
    cl = await aiohttp_client(srv.build())
    r = await cl.post("/api/ack", headers={"X-Token": TOKEN})
    assert r.status == 403
    j = await (await cl.get("/api/status", headers={"X-Token": TOKEN})).json()
    assert j["canAck"] is False


async def test_pause_and_resume(client):
    await client.post("/api/pause", headers={"X-Token": TOKEN})
    assert (await (await client.get("/api/status", headers={"X-Token": TOKEN})).json())["paused"]
    await client.post("/api/resume", headers={"X-Token": TOKEN})
    assert not (await (await client.get("/api/status", headers={"X-Token": TOKEN})).json())["paused"]


async def test_pwa_bits(client):
    r = await client.get("/manifest.webmanifest", headers={"X-Token": TOKEN})
    assert r.status == 200
    m = json.loads(await r.text())
    assert m["display"] == "standalone"
    assert TOKEN in m["start_url"], "the installed icon must open already authorised"
    assert (await client.get("/icon.svg", headers={"X-Token": TOKEN})).status == 200
    assert (await client.get("/sw.js", headers={"X-Token": TOKEN})).status == 200


async def test_unknown_path_is_404(client):
    assert (await client.get("/nope", headers={"X-Token": TOKEN})).status == 404


async def test_empty_token_means_open(aiohttp_client):
    # documented behaviour, and the reason startup logs a warning about it
    mon = Monitor()
    mon.sync([HostSpec("A", "10.0.0.1")], 100)
    cl = await aiohttp_client(Server(mon, build_cfg(), "", "1.0.0").build())
    assert (await cl.get("/api/status")).status == 200
