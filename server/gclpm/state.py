"""Host state and alarm state.

This is a deliberate port of the Windows tool's semantics, not a redesign. In
particular the per-host `sound` switch controls **only** whether the alarm makes
a noise: a silenced host still goes red, still has to be acknowledged, and its
notifications still go out. Getting that wrong twice is what taught us to say it
out loud here.
"""

from __future__ import annotations

import logging
import time
from collections import deque
from dataclasses import dataclass, field

from .config import HostSpec

INIT, UP, WARN, DOWN, OFF = "INIT", "UP", "WARN", "DOWN", "OFF"

log = logging.getLogger("gclpm.event")


@dataclass
class Host:
    label: str
    target: str
    enabled: bool = True
    sound: bool = True

    status: str = INIT
    latency: float | None = None
    last_change: float | None = None
    down_since: float | None = None
    acked: bool = False
    fail_count: int = 0

    history: deque[bool] = field(default_factory=lambda: deque(maxlen=100))
    total_sent: int = 0
    total_lost: int = 0

    @property
    def key(self) -> str:
        return self.target.strip().lower()

    @property
    def loss_percent(self) -> int:
        if not self.history:
            return 0
        lost = sum(1 for ok in self.history if not ok)
        return int(round(lost * 100.0 / len(self.history)))

    def reset_stats(self) -> None:
        self.history.clear()
        self.total_sent = 0
        self.total_lost = 0


def fmt_duration(seconds: float) -> str:
    """Same shape as the Windows tool's Format-Duration, so a message from
    either side reads identically."""
    s = int(max(0, seconds))
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m {s % 60}s"
    if s < 86400:
        return f"{s // 3600}h {(s % 3600) // 60}m"
    return f"{s // 86400}d {(s % 86400) // 3600}h"


class Monitor:
    """Everything the pinger writes and the web/notifier read."""

    def __init__(self) -> None:
        self.hosts: dict[str, Host] = {}
        self.order: list[str] = []
        self.paused = False
        self.last_check: float | None = None
        self.log: deque[str] = deque(maxlen=60)
        # Seconds a host must stay down before the banner turns red and the
        # desk hears about it. The DOWN state itself is unaffected - the table
        # shows it immediately either way, and the phone channels can be told
        # straight away. This only holds back the alarm.
        self.alarm_delay: float = 0.0

    # ---- host list -----------------------------------------------------
    def sync(self, specs: list[HostSpec], loss_window: int,
             alarm_delay: float = 0.0) -> list[str]:
        """Apply a (re)loaded config without losing live state for hosts that
        are still present. Returns human-readable notes about what changed."""
        notes: list[str] = []
        self.alarm_delay = max(0.0, float(alarm_delay))
        wanted = {s.key: s for s in specs}

        for key in list(self.hosts):
            if key not in wanted:
                gone = self.hosts[key]
                notes.append(f"removed {gone.label} [{gone.target}]")
                # Mark it OFF before letting go. A delayed notification still
                # holds a reference to this object, and nothing will ever
                # update it again - so leaving it reading DOWN means email
                # arrives a minute later about a host that is no longer
                # monitored. Seen live on 9 Sep 2026: removed 14:32:09,
                # mailed 14:32:57.
                gone.status, gone.down_since, gone.acked = OFF, None, False
                del self.hosts[key]

        for spec in specs:
            host = self.hosts.get(spec.key)
            if host is None:
                host = Host(label=spec.label, target=spec.target,
                            enabled=spec.enabled, sound=spec.sound)
                host.history = deque(maxlen=loss_window)
                host.status = INIT if spec.enabled else OFF
                self.hosts[spec.key] = host
                notes.append(f"added {spec.label} [{spec.target}]")
                continue

            if host.label != spec.label:
                notes.append(f"renamed {host.label} -> {spec.label}")
                host.label = spec.label
            if host.enabled != spec.enabled:
                host.enabled = spec.enabled
                notes.append(f"{'enabled' if spec.enabled else 'disabled'} {host.label}")
                if spec.enabled:
                    # coming back from disabled: no stale UP/DOWN, and no stale
                    # acknowledgement either
                    host.status, host.fail_count, host.acked = INIT, 0, False
                    host.down_since = None
                else:
                    host.status, host.down_since, host.acked = OFF, None, False
            if host.sound != spec.sound:
                host.sound = spec.sound
                notes.append(f"sound {'on' if spec.sound else 'off'} for {host.label}")
            if host.history.maxlen != loss_window:
                host.history = deque(host.history, maxlen=loss_window)

        self.order = [s.key for s in specs]
        return notes

    def active(self) -> list[Host]:
        return [self.hosts[k] for k in self.order if k in self.hosts and self.hosts[k].enabled]

    def all(self) -> list[Host]:
        return [self.hosts[k] for k in self.order if k in self.hosts]

    # ---- alarm ---------------------------------------------------------
    def unacked_down(self) -> list[Host]:
        return [h for h in self.active() if h.status == DOWN and not h.acked]

    def alarming(self) -> list[Host]:
        """Un-acknowledged downs that have lasted long enough to alarm.

        Below `alarm_delay` a host is still DOWN, still red in the table, and
        the phone channels may already have been told - it just does not yet
        make noise. A blip that clears inside the window never alarms at all.
        """
        if self.alarm_delay <= 0:
            return self.unacked_down()
        cut = time.time() - self.alarm_delay
        return [h for h in self.unacked_down()
                if h.down_since is not None and h.down_since <= cut]

    @property
    def alarm_active(self) -> bool:
        return bool(self.alarming())

    @property
    def alarm_loud(self) -> bool:
        # the per-host switch decides noise and nothing else
        return any(h.sound for h in self.alarming())

    def acknowledge_all(self) -> int:
        n = 0
        for h in self.active():
            if h.status == DOWN and not h.acked:
                h.acked = True
                n += 1
        return n

    # ---- results -------------------------------------------------------
    def record(self, host: Host, rtt_ms: float | None, fail_threshold: int) -> str | None:
        """Fold one ping result in. Returns 'DOWN' or 'UP' if this result was
        the transition, otherwise None."""
        now = time.time()
        ok = rtt_ms is not None
        host.history.append(ok)
        host.total_sent += 1
        if not ok:
            host.total_lost += 1

        event: str | None = None
        if ok:
            host.latency = rtt_ms
            host.fail_count = 0
            if host.status != UP:
                if host.status == DOWN:
                    event = "UP"
                host.status = UP
                host.last_change = now
                # a host that comes back clears its own acknowledgement, so the
                # next outage alarms again instead of starting pre-silenced
                host.acked = False
        else:
            host.latency = None
            host.fail_count += 1
            if host.fail_count >= fail_threshold:
                if host.status != DOWN:
                    host.status = DOWN
                    host.last_change = now
                    host.down_since = now
                    host.acked = False
                    event = "DOWN"
            elif host.status != DOWN:
                host.status = WARN
        return event

    def note(self, line: str) -> None:
        self.log.append(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {line}")
        # Also to stdout, where docker's json-file driver keeps 30 MB of it.
        # The deque above holds 60 lines and dies with the process, so the
        # first time anyone asked "when did this start flapping?" the answer
        # had already scrolled away. Investigating an intermittent fault needs
        # days of history, not the last few minutes of it.
        log.info("%s", line)
