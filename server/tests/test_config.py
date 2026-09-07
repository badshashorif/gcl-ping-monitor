"""Config loading, plus the guard that keeps the dashboard identical to the
Windows tool's copy."""

import re
import textwrap
from pathlib import Path

import pytest

from gclpm import config as cfgmod

REPO = Path(__file__).resolve().parents[2]


def write(tmp_path, text):
    p = tmp_path / "config.yml"
    p.write_text(textwrap.dedent(text), encoding="utf-8")
    return p


def test_missing_sections_fall_back_to_defaults(tmp_path):
    # a config that mentions only hosts must not KeyError somewhere deep later
    cfg = cfgmod.load(write(tmp_path, """
        hosts:
          - target: 10.0.0.1
    """))
    assert cfg.notify["batch_seconds"] == 20
    assert cfg.web["port"] == 8080
    assert cfg.notify["ntfy"]["down_priority"] == 5
    assert cfg.notify["repeat_min"] == 0


def test_partial_section_keeps_sibling_defaults(tmp_path):
    cfg = cfgmod.load(write(tmp_path, """
        notify:
          ntfy:
            enabled: true
            topic: mine
        hosts: []
    """))
    assert cfg.notify["ntfy"]["enabled"] is True
    assert cfg.notify["ntfy"]["server"] == "https://ntfy.sh", "a sibling default"
    assert cfg.notify["email"]["enabled"] is False, "a whole untouched section"


def test_host_shorthand_and_defaults(tmp_path):
    cfg = cfgmod.load(write(tmp_path, """
        hosts:
          - 8.8.8.8
          - label: RTR
            target: 10.0.0.1
            enabled: false
            sound: false
    """))
    a, b = cfg.hosts
    assert a.label == "8.8.8.8" and a.enabled and a.sound, "bare string = enabled, loud"
    assert b.label == "RTR" and not b.enabled and not b.sound


def test_duplicate_targets_are_dropped(tmp_path, caplog):
    cfg = cfgmod.load(write(tmp_path, """
        hosts:
          - {label: A, target: 10.0.0.1}
          - {label: B, target: 10.0.0.1}
    """))
    # two rows for one device means two alarms and two messages for one outage
    assert len(cfg.hosts) == 1


def test_blank_targets_are_ignored(tmp_path):
    cfg = cfgmod.load(write(tmp_path, """
        hosts:
          - {label: A, target: ""}
          - {label: B, target: 10.0.0.2}
    """))
    assert [h.target for h in cfg.hosts] == ["10.0.0.2"]


def test_secrets_come_only_from_the_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("GCLPM_WEB_TOKEN", "sekrit")
    monkeypatch.setenv("GCLPM_NTFY_TOKEN", "tk_abc")
    cfg = cfgmod.load(write(tmp_path, "hosts: []"))
    assert cfg.secret("web_token") == "sekrit"
    assert cfg.secret("ntfy_token") == "tk_abc"
    assert cfg.secret("telegram_token") == ""
    assert "sekrit" not in cfg.path.read_text(), "config.yml must never hold a secret"


def test_bad_yaml_raises_rather_than_half_loading(tmp_path):
    with pytest.raises(Exception):
        cfgmod.load(write(tmp_path, "hosts: [unclosed\n"))


def test_top_level_must_be_a_mapping(tmp_path):
    with pytest.raises(ValueError):
        cfgmod.load(write(tmp_path, "- just\n- a list\n"))


def test_shipped_example_config_actually_loads(tmp_path):
    # a broken example is worse than none: it is the first thing anyone copies
    src = (REPO / "server" / "config.example.yml").read_text(encoding="utf-8")
    cfg = cfgmod.load(write(tmp_path, src))
    assert len(cfg.hosts) >= 1
    assert cfg.interval >= 1


def test_changed_on_disk(tmp_path):
    p = write(tmp_path, "hosts: []")
    cfg = cfgmod.load(p)
    assert not cfgmod.changed_on_disk(cfg)
    import os, time
    os.utime(p, (time.time() + 10, time.time() + 10))
    assert cfgmod.changed_on_disk(cfg)


# ---- the two copies of the dashboard must not drift ----------------------
def test_dashboard_matches_the_windows_copy():
    """The .ps1 embeds the page as a here-string (it has to - it ships as one
    file). This server serves a extracted copy. If someone edits one and not the
    other, the phone and the desk start disagreeing about what the UI does."""
    ps1 = (REPO / "GCL-PingMonitor.ps1").read_text(encoding="utf-8")
    html = (REPO / "server" / "gclpm" / "static" / "dashboard.html").read_text(encoding="utf-8")

    m = re.search(r"\$script:WebPage = @'\r?\n(.*?)\r?\n'@", ps1, re.S)
    assert m, "could not find the WebPage here-string in GCL-PingMonitor.ps1"
    embedded = m.group(1).replace("\r\n", "\n").strip()

    assert embedded == html.strip(), (
        "GCL-PingMonitor.ps1 and server/gclpm/static/dashboard.html have drifted. "
        "Edit the .ps1, then re-run tools/extract-dashboard."
    )


def test_dashboard_is_pure_ascii():
    """The .ps1 ships without a BOM and PowerShell 5.1 reads such a file as
    ANSI, so a literal emoji in the page reaches the browser as mojibake."""
    html = (REPO / "server" / "gclpm" / "static" / "dashboard.html").read_bytes()
    bad = [b for b in html if b > 127]
    assert not bad, f"{len(bad)} non-ASCII bytes in dashboard.html"


def test_dashboard_loads_nothing_from_the_internet():
    """The phone reading this may be on a management VLAN with no route out."""
    html = (REPO / "server" / "gclpm" / "static" / "dashboard.html").read_text(encoding="utf-8")
    assert not re.search(r"<script[^>]+src=", html)
    assert not re.search(r"<link[^>]+stylesheet", html)
    assert "@import" not in html
    assert "fonts.googleapis" not in html
