"""Grouping hosts into network layers.

A group is presentation only: it decides which heading a row is drawn under
and nothing else. Every test here exists to hold that line - a device must
never stop being pinged, lose its history, or drop an acknowledgement because
somebody moved it between layers or mistyped a group name.

The order of `groups:` in config.yml IS the hierarchy the dashboard draws,
which is why it round-trips rather than being sorted or rebuilt.
"""

from __future__ import annotations

import time

import pytest

from gclpm import config as cfgmod
from gclpm import editor
from gclpm.config import HostSpec
from gclpm.state import DOWN, UP, Monitor
from gclpm.web import Server


def write(tmp_path, text):
    p = tmp_path / "config.yml"
    p.write_text(text, encoding="utf-8")
    return p


BASE = """\
groups:
  - UPSTREAM_PEER
  - CORE_RTR
  - POP_RTR
hosts:
  - label: EXABYTE
    target: 10.101.1.125
    group: UPSTREAM_PEER
  - label: NCS540
    target: 172.30.100.1
    group: CORE_RTR
  - label: STRAY
    target: 10.0.0.9
"""


# ---- the hierarchy comes from the file, not from the data -----------------
def test_group_order_is_the_configured_order(tmp_path):
    cfg = cfgmod.load(write(tmp_path, BASE))
    # POP_RTR has no hosts yet and still holds its place - a layer you are
    # about to fill should not jump position the moment you fill it
    assert cfg.groups == ["UPSTREAM_PEER", "CORE_RTR", "POP_RTR", "Ungrouped"]


def test_ungrouped_only_appears_when_something_needs_it(tmp_path):
    cfg = cfgmod.load(write(tmp_path, BASE.replace("  - label: STRAY\n    target: 10.0.0.9\n", "")))
    assert "Ungrouped" not in cfg.groups


def test_a_group_only_a_host_names_is_added_not_dropped(tmp_path):
    """A typo must show up as a heading, not swallow the device."""
    src = BASE + "  - label: TYPO\n    target: 10.0.0.10\n    group: COER_RTR\n"
    cfg = cfgmod.load(write(tmp_path, src))
    assert "COER_RTR" in cfg.groups
    assert [h.label for h in cfg.hosts if h.group == "COER_RTR"] == ["TYPO"]


def test_the_reserved_bucket_cannot_be_joined(tmp_path):
    """"Ungrouped" as a host's group means no group, not a group of that name,
    or the page would draw two headings that mean the same thing."""
    src = BASE + "  - label: ODD\n    target: 10.0.0.11\n    group: Ungrouped\n"
    cfg = cfgmod.load(write(tmp_path, src))
    assert [h.group for h in cfg.hosts if h.label == "ODD"] == [""]
    assert cfg.groups.count("Ungrouped") == 1


def test_no_groups_key_still_loads(tmp_path):
    cfg = cfgmod.load(write(tmp_path, "hosts:\n  - target: 10.0.0.1\n"))
    assert cfg.groups == ["Ungrouped"]


# ---- editing ---------------------------------------------------------------
@pytest.fixture()
def cfg_file(tmp_path):
    return write(tmp_path, BASE)


def test_group_survives_a_save(cfg_file):
    hosts, groups = editor.save_hosts(
        cfg_file,
        [{"label": "NCS540", "target": "172.30.100.1", "group": "CORE_RTR"}],
        ["UPSTREAM_PEER", "CORE_RTR", "POP_RTR"],
    )
    assert hosts[0]["group"] == "CORE_RTR"
    assert groups == ["UPSTREAM_PEER", "CORE_RTR", "POP_RTR"]
    assert cfgmod.load(cfg_file).hosts[0].group == "CORE_RTR"


def test_an_ungrouped_host_writes_no_group_line(cfg_file):
    editor.save_hosts(cfg_file, [{"label": "A", "target": "10.0.0.1"}], [])
    assert "group:" not in cfg_file.read_text(encoding="utf-8")


def test_one_spelling_per_group(cfg_file):
    """"core_rtr" typed on one row must not become a second heading."""
    hosts, groups = editor.save_hosts(
        cfg_file,
        [{"label": "A", "target": "10.0.0.1", "group": "core_rtr"},
         {"label": "B", "target": "10.0.0.2", "group": "CORE_RTR"}],
        ["CORE_RTR"],
    )
    assert [h["group"] for h in hosts] == ["CORE_RTR", "CORE_RTR"]
    assert groups == ["CORE_RTR"]


def test_saving_keeps_a_group_the_list_forgot(cfg_file):
    """The browser posts the list it knows about; a group only a row names
    still has to be written, or the next load re-homes that host."""
    _, groups = editor.save_hosts(
        cfg_file, [{"label": "A", "target": "10.0.0.1", "group": "NEW_LAYER"}], [])
    assert groups == ["NEW_LAYER"]


def test_read_groups_sees_declared_and_used(cfg_file):
    assert editor.read_groups(cfg_file) == ["UPSTREAM_PEER", "CORE_RTR", "POP_RTR"]


def test_comments_survive_a_grouped_save(tmp_path):
    src = "# keep me\ngroups:\n  - CORE_RTR\nhosts:\n  - target: 10.0.0.1\n"
    p = write(tmp_path, src)
    editor.save_hosts(p, [{"target": "10.0.0.1", "group": "CORE_RTR"}], ["CORE_RTR"])
    assert "# keep me" in p.read_text(encoding="utf-8")


def test_too_many_groups_is_refused(cfg_file):
    with pytest.raises(editor.ValidationError):
        editor.save_hosts(cfg_file, [], [f"G{i}" for i in range(editor.MAX_GROUPS + 1)])


# ---- moving a host between layers must cost it nothing ---------------------
def test_regrouping_keeps_history_and_acknowledgement():
    mon = Monitor()
    mon.sync([HostSpec("NCS540", "172.30.100.1", group="CORE_RTR")], 100)
    host = mon.hosts["172.30.100.1"]
    host.status, host.down_since, host.acked = DOWN, time.time() - 300, True
    host.history.extend([True, False, True])
    since = host.down_since

    notes = mon.sync([HostSpec("NCS540", "172.30.100.1", group="CORE_SW")], 100)

    assert host.group == "CORE_SW"
    assert host.status == DOWN and host.acked is True and host.down_since == since
    assert list(host.history) == [True, False, True]
    assert any("moved" in n for n in notes)


# ---- the contract ----------------------------------------------------------
class _Cfg:
    """Just enough config for a Server to build a snapshot."""

    def __init__(self, groups):
        self._groups = groups
        self.raw = {}
        self.path = None
        self.monitor_name = "TEST"
        self.web = {"allow_ack": True, "allow_edit": False}

    @property
    def groups(self):
        return self._groups


def _snapshot(specs, groups, statuses):
    mon = Monitor()
    mon.sync(specs, 100)
    for target, status in statuses.items():
        mon.hosts[target].status = status
    return Server(mon, _Cfg(groups), "", "test").snapshot()


def test_snapshot_carries_the_group_and_a_tally():
    snap = _snapshot(
        [HostSpec("A", "10.0.0.1", group="CORE_RTR"),
         HostSpec("B", "10.0.0.2", group="CORE_RTR"),
         HostSpec("C", "10.0.0.3", group="POP_RTR")],
        ["CORE_RTR", "POP_RTR"],
        {"10.0.0.1": DOWN, "10.0.0.2": UP, "10.0.0.3": UP},
    )
    assert [h["group"] for h in snap["hosts"]] == ["CORE_RTR", "CORE_RTR", "POP_RTR"]
    core = [g for g in snap["groups"] if g["name"] == "CORE_RTR"][0]
    assert (core["total"], core["down"], core["up"]) == (2, 1, 1)


def test_a_group_tally_counts_a_disabled_host_as_off():
    snap = _snapshot(
        [HostSpec("A", "10.0.0.1", group="CORE_RTR", enabled=False)],
        ["CORE_RTR"], {},
    )
    core = snap["groups"][0]
    assert (core["total"], core["off"], core["up"], core["down"]) == (1, 1, 0, 0)


def test_group_tallies_add_up_to_the_banner():
    """Two places counting the same hosts is two places to disagree."""
    snap = _snapshot(
        [HostSpec("A", "10.0.0.1", group="CORE_RTR"),
         HostSpec("B", "10.0.0.2", group="POP_RTR"),
         HostSpec("C", "10.0.0.3")],
        ["CORE_RTR", "POP_RTR", "Ungrouped"],
        {"10.0.0.1": DOWN, "10.0.0.2": UP, "10.0.0.3": UP},
    )
    assert sum(g["total"] for g in snap["groups"]) == snap["counts"]["total"]
    assert sum(g["down"] for g in snap["groups"]) == snap["counts"]["down"]
    assert sum(g["up"] for g in snap["groups"]) == snap["counts"]["up"]
