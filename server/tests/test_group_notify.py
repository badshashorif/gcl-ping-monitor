"""Which channels a layer is allowed to interrupt people through.

Seventeen retail access routers at the far end of somebody else's fibre will
flap. That is worth a line in Telegram and not worth a phone ringing, so a
layer can be narrowed to the channels that suit it.

What it must never touch: the host is still pinged, still goes red, still has
to be acknowledged, and still makes whatever noise its own `sound` flag says.
This is about the interruption, not the monitoring - and every test here
exists to hold that line.
"""

from __future__ import annotations

import time

import pytest

from gclpm.config import Config, DEFAULTS, HostSpec
from gclpm.notify import Notifier
from gclpm.state import DOWN, UP, Monitor


def make(policy: dict, delays: dict | None = None):
    """A monitor with one host per layer, and a notifier that records sends."""
    delays = delays or {}
    raw = {
        **DEFAULTS,
        "group_notify": policy,
        "notify": {
            **DEFAULTS["notify"],
            "repeat_min": 0,
            **{c: {**DEFAULTS["notify"][c], "enabled": True,
                   "delay_seconds": delays.get(c, 0)}
               for c in ("email", "telegram", "ntfy")},
        },
    }
    cfg = Config(raw=raw)
    mon = Monitor()
    mon.sync([HostSpec("RETAIL_1", "10.0.0.1", group="RETAIL_ACCESS_RTR"),
              HostSpec("CORE_1", "10.0.0.2", group="CORE_RTR")], 100)

    sent: list[tuple[str, str]] = []
    n = Notifier(cfg, "TEST", lambda _s: None)

    async def fake_send(subject, body, short, critical, channels=None):
        for ch in (channels or ["email", "telegram", "ntfy"]):
            sent.append((ch, body))

    n._send = fake_send                        # type: ignore[method-assign]
    return mon, n, sent


def channels_of(sent):
    return {ch for ch, _ in sent}


def down(mon, target):
    h = mon.hosts[target]
    h.status, h.down_since, h.acked = DOWN, time.time(), False
    return h


# ---- the rule itself -------------------------------------------------------
@pytest.mark.asyncio
async def test_a_narrowed_layer_reaches_only_its_channels():
    mon, n, sent = make({"RETAIL_ACCESS_RTR": ["telegram"]})
    n.add("DOWN", down(mon, "10.0.0.1"))
    await n.flush()
    assert channels_of(sent) == {"telegram"}
    assert n.queue == [], "the muted channels must finish with it, not hold it"


@pytest.mark.asyncio
async def test_an_unlisted_layer_still_gets_everything():
    mon, n, sent = make({"RETAIL_ACCESS_RTR": ["telegram"]})
    n.add("DOWN", down(mon, "10.0.0.2"))       # CORE_RTR, not in the policy
    await n.flush()
    assert channels_of(sent) == {"email", "telegram", "ntfy"}


@pytest.mark.asyncio
async def test_an_empty_list_means_the_dashboard_only():
    """`[]` and "not configured" are opposites, and both are legitimate."""
    mon, n, sent = make({"RETAIL_ACCESS_RTR": []})
    n.add("DOWN", down(mon, "10.0.0.1"))
    await n.flush()
    assert sent == []
    assert n.queue == []


@pytest.mark.asyncio
async def test_one_message_can_carry_two_layers_with_different_policies():
    """A single flush fans out to three channels; each must carry only the
    hosts that layer is allowed to tell it about."""
    mon, n, sent = make({"RETAIL_ACCESS_RTR": ["telegram"]})
    n.add("DOWN", down(mon, "10.0.0.1"))       # telegram only
    n.add("DOWN", down(mon, "10.0.0.2"))       # everything
    await n.flush()

    by = {ch: body for ch, body in sent}
    assert "RETAIL_1" in by["telegram"] and "CORE_1" in by["telegram"]
    for ch in ("email", "ntfy"):
        assert "CORE_1" in by[ch]
        assert "RETAIL_1" not in by[ch], f"{ch} was told about a layer it must not be"


@pytest.mark.asyncio
async def test_a_muted_layer_costs_no_slot_of_the_hourly_cap():
    mon, n, sent = make({"RETAIL_ACCESS_RTR": []})
    n.add("DOWN", down(mon, "10.0.0.1"))
    await n.flush()
    assert n.sent_times == [], "nothing was sent, so nothing should be counted"


@pytest.mark.asyncio
async def test_the_recovery_follows_the_same_policy():
    mon, n, sent = make({"RETAIL_ACCESS_RTR": ["telegram"]})
    h = down(mon, "10.0.0.1")
    n.add("DOWN", h)
    await n.flush()
    sent.clear()

    h.status, h.down_since = UP, None
    n.add("UP", h)
    await n.flush()
    assert channels_of(sent) == {"telegram"}, "no RECOVERED where no DOWN went"


@pytest.mark.asyncio
async def test_a_reminder_follows_the_same_policy():
    mon, n, sent = make({"RETAIL_ACCESS_RTR": ["telegram"]})
    n.cfg.raw["notify"]["repeat_min"] = 1
    h = down(mon, "10.0.0.1")
    n.add("DOWN", h)
    await n.flush()
    sent.clear()

    n.last_sent = time.time() - 120
    await n.reminder([h])
    assert channels_of(sent) == {"telegram"}


@pytest.mark.asyncio
async def test_the_policy_narrows_but_never_switches_a_channel_on():
    mon, n, sent = make({"RETAIL_ACCESS_RTR": ["telegram", "ntfy"]})
    n.cfg.raw["notify"]["ntfy"]["enabled"] = False
    n.add("DOWN", down(mon, "10.0.0.1"))
    await n.flush()
    assert channels_of(sent) == {"telegram"}


@pytest.mark.asyncio
async def test_a_delay_and_a_policy_together():
    """email is muted for this layer, so its 60s window is never even reached."""
    mon, n, sent = make({"RETAIL_ACCESS_RTR": ["telegram"]}, delays={"email": 60})
    n.add("DOWN", down(mon, "10.0.0.1"))
    await n.flush()
    assert channels_of(sent) == {"telegram"}
    sent.clear()
    for e in n.queue:
        e.at -= 61
    await n.flush()
    assert sent == [], "a muted channel must not wake up when its delay expires"


# ---- what it must not touch ------------------------------------------------
def test_a_muted_layer_still_goes_red_and_still_alarms():
    mon, n, sent = make({"RETAIL_ACCESS_RTR": []})
    h = down(mon, "10.0.0.1")
    assert h.status == DOWN
    assert mon.unacked_down() == [h]
    assert mon.alarm_active is True and mon.alarm_loud is True


def test_the_lookup_tells_missing_apart_from_deliberately_empty():
    cfg = Config(raw={**DEFAULTS, "group_notify": {"A": ["telegram"], "B": []}})
    assert cfg.channels_for("A") == {"telegram"}
    assert cfg.channels_for("B") == set()
    assert cfg.channels_for("C") is None
    assert cfg.channels_for("") is None


def test_a_single_channel_may_be_written_without_the_list_brackets():
    cfg = Config(raw={**DEFAULTS, "group_notify": {"A": "telegram"}})
    assert cfg.channels_for("A") == {"telegram"}


def test_a_null_in_the_file_means_silence_not_everything():
    # `RETAIL_ACCESS_RTR:` with nothing after it parses as None, and reading
    # that as "no restriction" would be the opposite of what was written
    cfg = Config(raw={**DEFAULTS, "group_notify": {"A": None}})
    assert cfg.channels_for("A") == set()
