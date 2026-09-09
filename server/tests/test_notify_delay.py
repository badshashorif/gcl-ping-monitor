"""Per-channel notification delay, and the alarm delay.

The rule these encode: the phone hears about a host the moment it goes down,
but the inbox and the noise at the desk only if it is still down a minute
later. A blip that clears inside the window must leave no mail at all - not a
DOWN, and not a RECOVERED either.

Time is moved by rewriting `at`/`down_since` rather than sleeping, so the whole
file runs in milliseconds.
"""

from __future__ import annotations

import time

import pytest

from gclpm.config import Config, DEFAULTS, HostSpec
from gclpm.notify import Notifier
from gclpm.state import DOWN, UP, Monitor


def make(delays: dict[str, int], alarm_delay: int = 0):
    """A monitor with one host, and a notifier whose sends are recorded."""
    raw = {
        **DEFAULTS,
        "alarm": {"delay_seconds": alarm_delay},
        "notify": {
            **DEFAULTS["notify"],
            "repeat_min": 0,
            "email": {**DEFAULTS["notify"]["email"], "enabled": True,
                      "delay_seconds": delays.get("email", 0)},
            "telegram": {**DEFAULTS["notify"]["telegram"], "enabled": True,
                         "delay_seconds": delays.get("telegram", 0)},
            "ntfy": {**DEFAULTS["notify"]["ntfy"], "enabled": True,
                     "delay_seconds": delays.get("ntfy", 0)},
        },
    }
    cfg = Config(raw=raw)
    mon = Monitor()
    mon.sync([HostSpec("RTR", "10.0.0.1")], 100, alarm_delay)
    host = mon.hosts["10.0.0.1"]

    sent: list[tuple[str, str]] = []          # (channel, subject)

    n = Notifier(cfg, "TEST", lambda _s: None)

    async def fake_send(subject, body, short, critical, channels=None):
        for ch in (channels or ["email", "telegram", "ntfy"]):
            sent.append((ch, subject))

    n._send = fake_send                        # type: ignore[method-assign]
    return mon, host, n, sent


def age(n: Notifier, seconds: float) -> None:
    """Pretend every queued event was raised `seconds` ago."""
    for e in n.queue:
        e.at -= seconds


def channels_of(sent) -> set[str]:
    return {ch for ch, _ in sent}


@pytest.mark.asyncio
async def test_phone_is_told_at_once_and_mail_waits():
    mon, host, n, sent = make({"email": 60})
    host.status, host.down_since = DOWN, time.time()
    n.add("DOWN", host)

    await n.flush()
    assert channels_of(sent) == {"telegram", "ntfy"}, "mail must not go yet"

    sent.clear()
    age(n, 61)
    await n.flush()
    assert channels_of(sent) == {"email"}, "mail goes once the minute is up"


@pytest.mark.asyncio
async def test_a_blip_never_reaches_the_inbox():
    """Down and back inside the window: no DOWN mail, and no RECOVERED either."""
    mon, host, n, sent = make({"email": 60})
    host.status, host.down_since = DOWN, time.time()
    n.add("DOWN", host)
    await n.flush()
    assert channels_of(sent) == {"telegram", "ntfy"}

    sent.clear()
    host.status, host.down_since = UP, None      # recovered after ~20s
    n.add("UP", host)
    age(n, 20)
    await n.flush()

    assert "email" not in channels_of(sent), "an orphan RECOVERED is worse than silence"
    assert channels_of(sent) == {"telegram", "ntfy"}
    assert n.queue == [], "the expired DOWN must not sit in the queue for ever"


@pytest.mark.asyncio
async def test_mail_gets_the_recovery_for_an_outage_it_was_told_about():
    mon, host, n, sent = make({"email": 60})
    host.status, host.down_since = DOWN, time.time()
    n.add("DOWN", host)
    await n.flush()
    age(n, 61)
    await n.flush()                              # email now knows it is down

    sent.clear()
    host.status, host.down_since = UP, None
    n.add("UP", host)
    await n.flush()
    assert "email" in channels_of(sent)


@pytest.mark.asyncio
async def test_a_host_deleted_inside_the_window_is_not_mailed_about():
    """Caught live on 9 Sep 2026: removed at 14:32:09, mailed at 14:32:57.

    A pending delayed alert keeps a reference to the Host, and once the host
    leaves the config nothing updates that object again - so it read DOWN for
    ever and the delay expired into a mail about a host nobody is watching.
    """
    mon, host, n, sent = make({"email": 60})
    host.status, host.down_since = DOWN, time.time()
    n.add("DOWN", host)
    await n.flush()
    assert channels_of(sent) == {"telegram", "ntfy"}

    sent.clear()
    mon.sync([], 100, 0)                     # the host is taken out of the config
    age(n, 61)
    await n.flush()

    assert sent == [], "no mail about a host that is no longer monitored"
    assert n.queue == []


@pytest.mark.asyncio
async def test_zero_delay_everywhere_behaves_exactly_as_before():
    mon, host, n, sent = make({})
    host.status, host.down_since = DOWN, time.time()
    n.add("DOWN", host)
    await n.flush()
    assert channels_of(sent) == {"email", "telegram", "ntfy"}
    assert n.queue == []


@pytest.mark.asyncio
async def test_one_flush_costs_one_slot_of_the_hourly_cap():
    """Splitting the fan-out must not silently triple the send rate."""
    mon, host, n, sent = make({"email": 60})
    host.status, host.down_since = DOWN, time.time()
    n.add("DOWN", host)
    await n.flush()
    assert len(n.sent_times) == 1


def test_alarm_waits_but_the_host_is_down_immediately():
    mon, host, n, sent = make({}, alarm_delay=60)
    host.status, host.down_since, host.acked = DOWN, time.time(), False

    assert mon.unacked_down(), "the table still shows it down straight away"
    assert mon.alarm_active is False, "but the desk stays quiet inside the window"

    host.down_since = time.time() - 61
    assert mon.alarm_active is True
    assert mon.alarm_loud is True


def test_alarm_delay_zero_is_the_old_behaviour():
    mon, host, n, sent = make({}, alarm_delay=0)
    host.status, host.down_since, host.acked = DOWN, time.time(), False
    assert mon.alarm_active is True
