"""Tests for the ping engine.

These do not send ICMP. `icmp_ping` is replaced with a stub, which lets the
tests assert the two properties the 9 Sep 2026 accuracy fix depends on and
that a live network could never demonstrate reliably:

  * a dead host costs exactly ONE probe, not `probes` of them - otherwise a
    single unreachable host stretches every cycle past the poll interval
  * a reachable host is measured `probes` times and reported at its best,
    so one slow sample cannot invent latency that is not there
"""

from __future__ import annotations

import asyncio

import pytest

from gclpm import pinger as pinger_mod
from gclpm.pinger import Pinger
from gclpm.state import Host


class FakeReply:
    def __init__(self, rtt: float | None) -> None:
        self.is_alive = rtt is not None
        self.packets_received = 1 if rtt is not None else 0
        self.min_rtt = rtt if rtt is not None else 0.0
        self.avg_rtt = rtt if rtt is not None else 0.0


def make_pinger(monkeypatch, rtts_by_target, calls) -> Pinger:
    """rtts_by_target: target -> list of RTTs (None = no reply), consumed in order."""

    def fake_ping(target, count, timeout, privileged):
        calls.append(target)
        queue = rtts_by_target[target]
        rtt = queue.pop(0) if queue else None
        return FakeReply(rtt)

    monkeypatch.setattr(pinger_mod, "icmp_ping", fake_ping)
    # No sleeping between probes - the interval is not what is under test.
    return Pinger(timeout=1.5, probes=3, probe_interval=0)


def host(target: str) -> Host:
    return Host(label=target, target=target)


def test_dead_host_costs_one_probe(monkeypatch):
    """The whole reason probes stop early: 3x timeout would blow the cycle."""
    calls: list[str] = []
    p = make_pinger(monkeypatch, {"10.0.0.1": [None, 1.0, 1.0]}, calls)
    try:
        assert asyncio.run(p.ping_one(host("10.0.0.1"))) is None
        assert calls == ["10.0.0.1"], "a dead host must not be probed 3 times"
    finally:
        p.close()


def test_live_host_reports_its_best_of_three(monkeypatch):
    """A single noisy sample must not reach the dashboard as real latency."""
    calls: list[str] = []
    p = make_pinger(monkeypatch, {"10.0.0.2": [227.0, 0.9, 0.4]}, calls)
    try:
        assert asyncio.run(p.ping_one(host("10.0.0.2"))) == pytest.approx(0.4)
        assert len(calls) == 3
    finally:
        p.close()


def test_later_probe_loss_does_not_mark_the_host_down(monkeypatch):
    """Alerting semantics are unchanged: only the first probe decides up/down."""
    calls: list[str] = []
    p = make_pinger(monkeypatch, {"10.0.0.3": [1.2, None, None]}, calls)
    try:
        assert asyncio.run(p.ping_one(host("10.0.0.3"))) == pytest.approx(1.2)
    finally:
        p.close()


def test_ping_all_keys_results_by_host_key(monkeypatch):
    calls: list[str] = []
    p = make_pinger(
        monkeypatch,
        {"10.0.0.4": [0.5, 0.6, 0.7], "10.0.0.5": [None]},
        calls,
    )
    try:
        out = asyncio.run(p.ping_all([host("10.0.0.4"), host("10.0.0.5")]))
        assert out == {"10.0.0.4": pytest.approx(0.5), "10.0.0.5": None}
    finally:
        p.close()


def test_empty_host_list_is_not_an_error(monkeypatch):
    p = make_pinger(monkeypatch, {}, [])
    try:
        assert asyncio.run(p.ping_all([])) == {}
    finally:
        p.close()


def test_socket_permission_is_reported_once(monkeypatch, caplog):
    """Otherwise the real cause drowns in one line per host per cycle."""
    from icmplib.exceptions import SocketPermissionError

    def fake_ping(target, count, timeout, privileged):
        raise SocketPermissionError("nope")

    monkeypatch.setattr(pinger_mod, "icmp_ping", fake_ping)
    p = Pinger(timeout=1.5, probes=3, probe_interval=0)
    try:
        with caplog.at_level("ERROR", logger="gclpm.ping"):
            asyncio.run(p.ping_all([host("10.0.0.6"), host("10.0.0.7")]))
        assert sum("cannot open an ICMP socket" in r.message for r in caplog.records) == 1
        assert p.resolves_ok() is False
    finally:
        p.close()
