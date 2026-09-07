"""The state machine: DOWN/UP transitions, the alarm, and the per-host sound
switch - which controls noise and nothing else."""

import time

import pytest

from gclpm.config import HostSpec
from gclpm.state import DOWN, INIT, OFF, UP, WARN, Monitor, fmt_duration


def make(*specs):
    mon = Monitor()
    mon.sync(list(specs), loss_window=100)
    return mon


def test_fail_threshold_needs_consecutive_misses():
    mon = make(HostSpec("A", "10.0.0.1"))
    h = mon.hosts["10.0.0.1"]

    assert mon.record(h, None, 2) is None
    assert h.status == WARN, "one miss is a warning, not an outage"

    assert mon.record(h, None, 2) == "DOWN"
    assert h.status == DOWN

    # already down: no second DOWN event, or every cycle would re-notify
    assert mon.record(h, None, 2) is None


def test_a_reply_resets_the_fail_count():
    mon = make(HostSpec("A", "10.0.0.1"))
    h = mon.hosts["10.0.0.1"]
    mon.record(h, None, 3)
    mon.record(h, 12.0, 3)
    assert h.status == UP and h.fail_count == 0
    mon.record(h, None, 3)
    assert h.status == WARN, "the counter must start again, not carry over"


def test_recovery_clears_a_stale_acknowledgement():
    mon = make(HostSpec("A", "10.0.0.1"))
    h = mon.hosts["10.0.0.1"]
    mon.record(h, None, 1)
    h.acked = True
    assert mon.record(h, 5.0, 1) == "UP"
    assert not h.acked, "the next outage must alarm, not start pre-silenced"


def test_silenced_host_still_alarms_but_not_loudly():
    mon = make(HostSpec("QUIET", "10.0.0.1", sound=False),
               HostSpec("LOUD", "10.0.0.2", sound=True))
    quiet = mon.hosts["10.0.0.1"]
    mon.record(quiet, None, 1)

    assert mon.alarm_active, "sound:false must NOT stop it being an alarm"
    assert not mon.alarm_loud

    loud = mon.hosts["10.0.0.2"]
    mon.record(loud, None, 1)
    assert mon.alarm_loud


def test_acknowledging_clears_the_alarm():
    mon = make(HostSpec("A", "10.0.0.1"))
    mon.record(mon.hosts["10.0.0.1"], None, 1)
    assert mon.alarm_active
    assert mon.acknowledge_all() == 1
    assert not mon.alarm_active
    assert mon.acknowledge_all() == 0, "acknowledging twice must not count twice"


def test_disabled_hosts_never_alarm():
    mon = make(HostSpec("A", "10.0.0.1", enabled=False))
    assert mon.hosts["10.0.0.1"].status == OFF
    assert mon.active() == []
    assert not mon.alarm_active


def test_loss_percent_uses_a_rolling_window():
    mon = Monitor()
    mon.sync([HostSpec("A", "10.0.0.1")], loss_window=10)
    h = mon.hosts["10.0.0.1"]
    for _ in range(10):
        mon.record(h, 1.0, 2)
    assert h.loss_percent == 0
    for _ in range(5):
        mon.record(h, None, 99)      # high threshold: stay out of DOWN
    assert h.loss_percent == 50
    for _ in range(10):
        mon.record(h, 1.0, 2)
    assert h.loss_percent == 0, "old samples must fall out of the window"


# ---- config reload -------------------------------------------------------
def test_reload_keeps_state_for_hosts_that_remain():
    mon = make(HostSpec("A", "10.0.0.1"), HostSpec("B", "10.0.0.2"))
    a = mon.hosts["10.0.0.1"]
    mon.record(a, None, 1)
    a.acked = True

    mon.sync([HostSpec("A", "10.0.0.1"), HostSpec("C", "10.0.0.3")], 100)
    assert mon.hosts["10.0.0.1"] is a, "the same object, so history survives"
    assert mon.hosts["10.0.0.1"].acked, "a reload must not un-acknowledge an outage"
    assert "10.0.0.2" not in mon.hosts
    assert "10.0.0.3" in mon.hosts


def test_renaming_a_host_keeps_its_history():
    mon = make(HostSpec("OLD", "10.0.0.1"))
    h = mon.hosts["10.0.0.1"]
    for _ in range(5):
        mon.record(h, 1.0, 2)
    mon.sync([HostSpec("NEW NAME", "10.0.0.1")], 100)
    assert mon.hosts["10.0.0.1"].label == "NEW NAME"
    assert mon.hosts["10.0.0.1"].total_sent == 5


def test_disabling_then_enabling_resets_cleanly():
    mon = make(HostSpec("A", "10.0.0.1"))
    mon.record(mon.hosts["10.0.0.1"], None, 1)
    assert mon.hosts["10.0.0.1"].status == DOWN

    mon.sync([HostSpec("A", "10.0.0.1", enabled=False)], 100)
    h = mon.hosts["10.0.0.1"]
    assert h.status == OFF and h.down_since is None and not h.acked

    mon.sync([HostSpec("A", "10.0.0.1", enabled=True)], 100)
    assert h.status == INIT, "must not come back still claiming to be DOWN"


def test_changing_the_loss_window_does_not_lose_the_host():
    mon = Monitor()
    mon.sync([HostSpec("A", "10.0.0.1")], loss_window=10)
    h = mon.hosts["10.0.0.1"]
    for _ in range(10):
        mon.record(h, 1.0, 2)
    mon.sync([HostSpec("A", "10.0.0.1")], loss_window=50)
    assert h.history.maxlen == 50
    assert len(h.history) == 10


@pytest.mark.parametrize("seconds,expected", [
    (0, "0s"), (45, "45s"), (60, "1m 0s"), (95, "1m 35s"),
    (3600, "1h 0m"), (3725, "1h 2m"), (86400, "1d 0h"),
])
def test_fmt_duration(seconds, expected):
    assert fmt_duration(seconds) == expected
