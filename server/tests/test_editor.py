"""The browser host editor.

Two separate worries here. The first is that a bad edit must be refused with a
message somebody can act on, rather than silently monitoring the wrong thing.
The second is that saving must not damage config.yml - the comments in it are
the only documentation most people will ever read, and a half-written file would
break the monitor at the exact moment nobody is watching it.
"""

import re
from pathlib import Path

import pytest

from gclpm import config as cfgmod
from gclpm import editor
from gclpm.state import Monitor
from gclpm.web import EDIT_ANCHOR, EDIT_LINK, Server

REPO = Path(__file__).resolve().parents[2]

SAMPLE = """\
# GCL Ping Monitor - server configuration
interval_seconds: 5

web:
  port: 8080
  allow_ack: true        # false makes the dashboard read-only

# label   what you call it
# sound   false = no NOISE at the desk
hosts:
  - label: RTR
    target: 10.0.0.1
  - label: OLD
    target: 10.0.0.9
    enabled: false
"""


@pytest.fixture
def cfg_file(tmp_path):
    p = tmp_path / "config.yml"
    p.write_text(SAMPLE, encoding="utf-8")
    return p


# ---- validation ----------------------------------------------------------
def test_missing_target_is_refused_by_row_number():
    with pytest.raises(editor.ValidationError) as exc:
        editor.normalise([{"label": "A", "target": "10.0.0.1"}, {"label": "B", "target": "  "}])
    assert "row 2" in str(exc.value)


@pytest.mark.parametrize("bad", [
    "http://10.0.0.1", "10.0.0.1:8080", "two words", "10.0.0.1/24", "-leading", "exclaim!.com",
])
def test_targets_that_would_never_resolve_are_refused(bad):
    # each of these fails as a silent DNS miss, which looks exactly like an outage
    with pytest.raises(editor.ValidationError):
        editor.normalise([{"target": bad}])


@pytest.mark.parametrize("good", ["10.0.0.1", "google.com", "a-b.example.co.uk", "2001:db8::1"])
def test_plain_addresses_and_names_are_accepted(good):
    assert editor.normalise([{"target": good}])[0]["target"] == good


def test_surrounding_whitespace_is_trimmed_not_rejected():
    # pasting from a spreadsheet drags a space along; that is not a mistake
    assert editor.normalise([{"target": "  10.0.0.1 "}])[0]["target"] == "10.0.0.1"


def test_duplicate_is_refused_rather_than_dropped():
    # dropping it would make a row vanish on save, which reads as "it failed"
    with pytest.raises(editor.ValidationError) as exc:
        editor.normalise([{"label": "Core A", "target": "10.0.0.1"},
                          {"label": "Core B", "target": "10.0.0.1"}])
    assert "Core A" in str(exc.value)


def test_blank_label_falls_back_to_the_target():
    assert editor.normalise([{"label": "  ", "target": "10.0.0.1"}])[0]["label"] == "10.0.0.1"


def test_label_is_trimmed_and_stripped_of_control_characters():
    row = editor.normalise([{"label": "  A\x00B\n ", "target": "10.0.0.1"}])[0]
    assert row["label"] == "AB"
    long = editor.normalise([{"label": "x" * 200, "target": "10.0.0.1"}])[0]
    assert len(long["label"]) == editor.MAX_LABEL


def test_flags_default_to_watched_and_loud():
    row = editor.normalise([{"target": "10.0.0.1"}])[0]
    assert row["enabled"] is True and row["sound"] is True


def test_a_silly_number_of_hosts_is_refused():
    with pytest.raises(editor.ValidationError):
        editor.normalise([{"target": f"10.1.{i // 256}.{i % 256}"}
                          for i in range(editor.MAX_HOSTS + 1)])


# ---- writing -------------------------------------------------------------
def test_save_keeps_the_comments_and_the_other_settings(cfg_file):
    editor.save_hosts(cfg_file, [{"label": "NEW", "target": "10.0.0.2"}])
    text = cfg_file.read_text(encoding="utf-8")

    assert "# GCL Ping Monitor - server configuration" in text
    assert "false makes the dashboard read-only" in text
    assert "sound   false = no NOISE at the desk" in text
    assert "interval_seconds: 5" in text
    assert "port: 8080" in text
    assert "10.0.0.1" not in text and "NEW" in text


def test_the_saved_file_still_loads(cfg_file):
    editor.save_hosts(cfg_file, [
        {"label": "A", "target": "10.0.0.1"},
        {"label": "B", "target": "10.0.0.2", "enabled": False, "sound": False},
    ])
    cfg = cfgmod.load(cfg_file)
    assert [h.target for h in cfg.hosts] == ["10.0.0.1", "10.0.0.2"]
    assert cfg.hosts[1].enabled is False and cfg.hosts[1].sound is False
    assert cfg.web["port"] == 8080, "the rest of the file survived"


def test_defaults_are_not_written_out(cfg_file):
    # a file where every row spells out enabled:true sound:true buries the two
    # lines that actually say something unusual
    editor.save_hosts(cfg_file, [{"label": "A", "target": "10.0.0.1"}])
    text = cfg_file.read_text(encoding="utf-8")
    assert "enabled" not in text and "sound: " not in text


def test_the_previous_version_is_kept(cfg_file):
    editor.save_hosts(cfg_file, [{"label": "A", "target": "10.0.0.1"}])
    bak = cfg_file.parent / (cfg_file.name + ".bak")
    assert "10.0.0.9" in bak.read_text(encoding="utf-8"), "the old host list is recoverable"


def test_a_rejected_save_changes_nothing(cfg_file):
    before = cfg_file.read_text(encoding="utf-8")
    with pytest.raises(editor.ValidationError):
        editor.save_hosts(cfg_file, [{"target": "10.0.0.1"}, {"target": "10.0.0.1"}])
    assert cfg_file.read_text(encoding="utf-8") == before
    assert not (cfg_file.parent / (cfg_file.name + ".tmp")).exists()


def test_saving_an_empty_list_is_allowed_but_visible(cfg_file):
    # legitimate while setting a new box up; the loader is what warns about it
    assert editor.save_hosts(cfg_file, []) == ([], [])
    assert cfgmod.load(cfg_file).hosts == []


def test_read_hosts_round_trips(cfg_file):
    rows = editor.read_hosts(cfg_file)
    assert rows == [
        {"label": "RTR", "target": "10.0.0.1", "enabled": True, "sound": True, "group": ""},
        {"label": "OLD", "target": "10.0.0.9", "enabled": False, "sound": True, "group": ""},
    ]


def test_read_hosts_understands_the_bare_string_shorthand(tmp_path):
    p = tmp_path / "config.yml"
    p.write_text("hosts:\n  - 8.8.8.8\n", encoding="utf-8")
    assert editor.read_hosts(p) == [
        {"label": "8.8.8.8", "target": "8.8.8.8", "enabled": True, "sound": True, "group": ""}]


# ---- over HTTP -----------------------------------------------------------
TOKEN = "testtoken123"


def make_server(cfg_path, **web_over):
    cfg = cfgmod.load(cfg_path)
    cfg.raw["web"].update(web_over)
    mon = Monitor()
    mon.sync(cfg.hosts, cfg.loss_window)
    return Server(mon, cfg, TOKEN, "1.0.0")


@pytest.fixture
async def client(aiohttp_client, cfg_file):
    srv = make_server(cfg_file)
    cl = await aiohttp_client(srv.build())
    cl.cfg_file = cfg_file
    return cl


async def test_editor_needs_the_token(client):
    assert (await client.get("/hosts")).status == 401
    assert (await client.get("/api/hosts")).status == 401
    assert (await client.post("/api/hosts", json={"hosts": []})).status == 401


async def test_get_hosts(client):
    j = await (await client.get("/api/hosts", headers={"X-Token": TOKEN})).json()
    assert [h["target"] for h in j["hosts"]] == ["10.0.0.1", "10.0.0.9"]


async def test_post_hosts_writes_the_file(client):
    r = await client.post("/api/hosts", headers={"X-Token": TOKEN},
                          json={"hosts": [{"label": "NEW", "target": "10.0.0.5"}]})
    assert r.status == 200
    assert (await r.json())["hosts"][0]["label"] == "NEW"
    assert "10.0.0.5" in client.cfg_file.read_text(encoding="utf-8")


async def test_a_bad_row_comes_back_as_400_with_the_row_number(client):
    before = client.cfg_file.read_text(encoding="utf-8")
    r = await client.post("/api/hosts", headers={"X-Token": TOKEN},
                          json={"hosts": [{"target": "10.0.0.1"}, {"target": "http://x"}]})
    assert r.status == 400
    assert "row 2" in (await r.json())["error"]
    assert client.cfg_file.read_text(encoding="utf-8") == before


async def test_malformed_body_is_400_not_500(client):
    r = await client.post("/api/hosts", headers={"X-Token": TOKEN}, data="not json")
    assert r.status == 400


async def test_saving_is_written_to_the_log(client):
    await client.post("/api/hosts", headers={"X-Token": TOKEN},
                      json={"hosts": [{"label": "A", "target": "10.0.0.1"}]})
    j = await (await client.get("/api/status", headers={"X-Token": TOKEN})).json()
    assert any("host list saved from a browser" in line for line in j["log"])


async def test_the_dashboard_links_to_the_editor(client):
    text = await (await client.get(f"/?t={TOKEN}")).text()
    assert EDIT_LINK in text
    assert text.index(EDIT_LINK) < text.index(EDIT_ANCHOR)


# ---- switched off --------------------------------------------------------
@pytest.fixture
async def locked(aiohttp_client, cfg_file):
    srv = make_server(cfg_file, allow_edit=False)
    return await aiohttp_client(srv.build())


async def test_allow_edit_false_hides_and_blocks_everything(locked, cfg_file):
    assert (await locked.get("/hosts", headers={"X-Token": TOKEN})).status == 404
    assert (await locked.get("/api/hosts", headers={"X-Token": TOKEN})).status == 403
    r = await locked.post("/api/hosts", headers={"X-Token": TOKEN},
                          json={"hosts": [{"target": "10.0.0.7"}]})
    assert r.status == 403
    assert "10.0.0.7" not in cfg_file.read_text(encoding="utf-8")

    text = await (await locked.get("/", headers={"X-Token": TOKEN})).text()
    assert EDIT_LINK not in text, "no link to a page that would 404"


async def test_a_config_with_no_file_cannot_be_edited(aiohttp_client):
    """The tests build configs in memory; so does anyone embedding this. The
    editor must switch itself off rather than crash on `path is None`."""
    raw = cfgmod._merge(cfgmod.DEFAULTS, {})
    srv = Server(Monitor(), cfgmod.Config(raw=raw, secrets={}), TOKEN, "1.0.0")
    assert srv.can_edit is False
    cl = await aiohttp_client(srv.build())
    assert (await cl.get("/api/hosts", headers={"X-Token": TOKEN})).status == 403


# ---- the page itself -----------------------------------------------------
def test_editor_page_loads_nothing_from_the_internet():
    html = (REPO / "server" / "gclpm" / "static" / "hosts.html").read_text(encoding="utf-8")
    assert not re.search(r"<script[^>]+src=", html)
    assert not re.search(r"<link[^>]+stylesheet", html)
    assert "@import" not in html and "fonts.googleapis" not in html
