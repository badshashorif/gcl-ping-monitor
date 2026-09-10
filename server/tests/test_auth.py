"""Accounts, passwords and roles.

The two properties worth more than all the others here:

  * with no users.yml, nothing changes. An upgrade that locks the operator
    out of their own monitoring dashboard is a worse failure than the one it
    was trying to prevent.
  * the notification link keeps working once accounts exist, at whatever
    `web.link_role` says, because a tapped alert at 3am has to land on the
    dashboard rather than a login form.
"""

from __future__ import annotations

import time

import pytest

from gclpm import auth
from gclpm import config as cfgmod
from gclpm.auth import AuthError, Sessions, User, Users
from gclpm.state import Monitor
from gclpm.web import Server

SAMPLE = """\
web:
  port: 8080
  allow_ack: true
  allow_edit: true
groups:
  - CORE_RTR
hosts:
  - label: RTR
    target: 10.0.0.1
    group: CORE_RTR
"""

GOOD = "correct-horse-battery"


@pytest.fixture
def cfg_file(tmp_path):
    p = tmp_path / "config.yml"
    p.write_text(SAMPLE, encoding="utf-8")
    return p


@pytest.fixture
def users(tmp_path):
    return Users(tmp_path / "users.yml")


# ---- password hashing ------------------------------------------------------
def test_a_hash_is_salted_and_verifies():
    a, b = auth.hash_password(GOOD), auth.hash_password(GOOD)
    assert a != b, "two hashes of one password must not match - that is the salt"
    assert auth.verify_password(a, GOOD)
    assert not auth.verify_password(a, GOOD + "x")


def test_the_plaintext_is_nowhere_in_the_hash():
    assert GOOD not in auth.hash_password(GOOD)


def test_a_short_password_is_refused():
    with pytest.raises(AuthError):
        auth.hash_password("short")


@pytest.mark.parametrize("junk", ["", "plain", "scrypt$notanumber$8$1$AA$AA", "a$b$c"])
def test_a_damaged_hash_fails_shut(junk):
    # a hash we cannot parse must never be treated as a match
    assert not auth.verify_password(junk, GOOD)


# ---- the user list ---------------------------------------------------------
def test_no_file_means_no_accounts(tmp_path):
    assert Users(tmp_path / "nope.yml").enabled is False


def test_a_user_round_trips_through_the_file(users):
    users.upsert("shorif", "admin", GOOD)
    again = Users(users.path)
    assert again.enabled
    assert again.check("shorif", GOOD).role == "admin"


def test_the_file_is_not_world_readable(users):
    users.upsert("shorif", "admin", GOOD)
    assert oct(users.path.stat().st_mode)[-3:] == "600"


def test_the_username_is_case_insensitive(users):
    users.upsert("Shorif", "admin", GOOD)
    assert users.check("SHORIF", GOOD).name == "shorif"


def test_a_wrong_password_and_a_missing_user_answer_the_same(users):
    users.upsert("shorif", "admin", GOOD)
    with pytest.raises(AuthError) as a:
        users.check("shorif", "wrong-password-here")
    with pytest.raises(AuthError) as b:
        users.check("nobody", "wrong-password-here")
    assert str(a.value) == str(b.value), "the form must not confirm who exists"


def test_repeated_failures_back_off(users):
    users.upsert("shorif", "admin", GOOD)
    for _ in range(auth.LOCK_AFTER):
        with pytest.raises(AuthError):
            users.check("shorif", "nope-nope-nope")
    # even the right password waits now
    with pytest.raises(AuthError) as exc:
        users.check("shorif", GOOD)
    assert "too many" in str(exc.value)


def test_a_good_login_clears_the_count(users):
    users.upsert("shorif", "admin", GOOD)
    with pytest.raises(AuthError):
        users.check("shorif", "wrong-password!")
    users.check("shorif", GOOD)
    assert users.locked_for("shorif") == 0


def test_the_only_admin_cannot_be_demoted_or_removed(users):
    users.upsert("shorif", "admin", GOOD)
    with pytest.raises(AuthError):
        users.upsert("shorif", "write")
    with pytest.raises(AuthError):
        users.remove("shorif")
    users.upsert("noc", "admin", GOOD)
    users.upsert("shorif", "write")          # fine now there are two
    assert users.users["shorif"].role == "write"


def test_updating_a_role_keeps_the_password(users):
    users.upsert("shorif", "admin", GOOD)
    users.upsert("noc", "admin", GOOD)
    users.upsert("shorif", "read")
    assert users.check("shorif", GOOD).role == "read"


@pytest.mark.parametrize("bad", ["", "a", "has space", "UPPER!", "-lead", "x" * 40])
def test_a_silly_username_is_refused(users, bad):
    with pytest.raises(AuthError):
        users.upsert(bad, "read", GOOD)


def test_an_unreadable_file_keeps_the_previous_list(users):
    users.upsert("shorif", "admin", GOOD)
    users.path.write_text("{{{ not yaml", encoding="utf-8")
    users.mtime = -1                      # force a re-read
    users.reload()
    assert "shorif" in users.users, "a broken file must not lock everyone out"


# ---- sessions --------------------------------------------------------------
def test_a_session_resolves_and_expires(users):
    users.upsert("shorif", "admin", GOOD)
    s = Sessions(hours=1)
    token = s.new(users.users["shorif"])
    assert s.user_of(token, users).name == "shorif"
    s._live[token] = ("shorif", time.time() - 1)
    assert s.user_of(token, users) is None


def test_a_role_change_takes_effect_without_a_new_login(users):
    users.upsert("shorif", "admin", GOOD)
    users.upsert("noc", "write", GOOD)
    s = Sessions()
    token = s.new(users.users["noc"])
    users.upsert("noc", "read")
    assert s.user_of(token, users).role == "read"


def test_removing_a_user_can_drop_their_sessions(users):
    users.upsert("shorif", "admin", GOOD)
    s = Sessions()
    token = s.new(users.users["shorif"])
    s.drop_user("shorif")
    assert s.user_of(token, users) is None


# ---- roles -----------------------------------------------------------------
@pytest.mark.parametrize("role,need,ok", [
    ("read", "read", True), ("read", "write", False), ("read", "admin", False),
    ("write", "read", True), ("write", "write", True), ("write", "admin", False),
    ("admin", "read", True), ("admin", "write", True), ("admin", "admin", True),
])
def test_the_ladder(role, need, ok):
    assert User("x", role).can(need) is ok


# ---- over HTTP -------------------------------------------------------------
TOKEN = "testtoken123"


def make_server(cfg_path, users):
    cfg = cfgmod.load(cfg_path)
    mon = Monitor()
    mon.sync(cfg.hosts, cfg.loss_window)
    return Server(mon, cfg, TOKEN, "1.0.0", users=users)


async def sign_in(client, name, password):
    r = await client.post("/api/login", json={"username": name, "password": password})
    assert r.status == 200, await r.text()
    return r


@pytest.fixture()
async def client(aiohttp_client, cfg_file, users):
    srv = make_server(cfg_file, users)
    cl = await aiohttp_client(srv.build())
    cl.users = users
    return cl


async def test_with_no_accounts_the_link_still_does_everything(client):
    """The opt-in rule. Nothing changes until somebody creates a user."""
    assert client.users.enabled is False
    for path in ("/api/status", "/api/hosts"):
        assert (await client.get(path, headers={"X-Token": TOKEN})).status == 200
    r = await client.post("/api/ack", headers={"X-Token": TOKEN})
    assert r.status == 200


async def test_a_bad_token_is_still_refused(client):
    assert (await client.get("/api/status", headers={"X-Token": "wrong"})).status == 401


async def test_once_a_user_exists_the_link_is_read_only(client):
    client.users.upsert("shorif", "admin", GOOD)
    h = {"X-Token": TOKEN}
    assert (await client.get("/api/status", headers=h)).status == 200
    assert (await client.post("/api/ack", headers=h)).status == 403
    assert (await client.get("/api/hosts", headers=h)).status == 403
    assert (await client.get("/api/users", headers=h)).status == 403


async def test_a_read_user_can_look_and_nothing_else(client):
    client.users.upsert("boss", "admin", GOOD)
    client.users.upsert("viewer", "read", GOOD)
    await sign_in(client, "viewer", GOOD)
    assert (await client.get("/api/status")).status == 200
    assert (await client.post("/api/ack")).status == 403
    assert (await client.post("/api/hosts", json={"hosts": []})).status == 403


async def test_a_write_user_can_change_the_estate_but_not_the_people(client):
    client.users.upsert("boss", "admin", GOOD)
    client.users.upsert("noc", "write", GOOD)
    await sign_in(client, "noc", GOOD)
    assert (await client.post("/api/ack")).status == 200
    r = await client.post("/api/hosts", json={
        "hosts": [{"label": "A", "target": "10.0.0.1", "group": "CORE_RTR"}],
        "groups": ["CORE_RTR"]})
    assert r.status == 200
    assert (await client.get("/api/users")).status == 403


async def test_an_admin_can_do_the_lot(client):
    client.users.upsert("boss", "admin", GOOD)
    await sign_in(client, "boss", GOOD)
    assert (await client.get("/api/users")).status == 200
    r = await client.post("/api/users", json={"name": "noc", "role": "write",
                                              "password": GOOD})
    assert r.status == 200
    assert [u["name"] for u in (await r.json())["users"]] == ["boss", "noc"]


async def test_the_api_never_hands_back_a_hash(client):
    client.users.upsert("boss", "admin", GOOD)
    await sign_in(client, "boss", GOOD)
    body = await (await client.get("/api/users")).text()
    assert "scrypt" not in body and GOOD not in body


async def test_a_wrong_password_is_401_and_says_nothing_useful(client):
    client.users.upsert("boss", "admin", GOOD)
    r = await client.post("/api/login", json={"username": "boss", "password": "nope!!!!!!"})
    assert r.status == 401
    assert "boss" not in (await r.json())["error"]


async def test_signing_out_ends_the_session_and_the_link_cookie(client):
    client.users.upsert("boss", "admin", GOOD)
    await sign_in(client, "boss", GOOD)
    assert (await client.get("/api/users")).status == 200
    assert (await client.post("/api/logout")).status == 200
    assert (await client.get("/api/users")).status == 401


async def test_an_admin_cannot_delete_the_account_they_are_using(client):
    client.users.upsert("boss", "admin", GOOD)
    client.users.upsert("other", "admin", GOOD)
    await sign_in(client, "boss", GOOD)
    r = await client.post("/api/users", json={"action": "remove", "name": "boss"})
    assert r.status == 400


async def test_the_snapshot_tells_the_page_what_it_may_offer(client):
    client.users.upsert("boss", "admin", GOOD)
    client.users.upsert("viewer", "read", GOOD)
    await sign_in(client, "viewer", GOOD)
    j = await (await client.get("/api/status")).json()
    assert j["you"] == {"name": "viewer", "role": "read", "auth": True}
    assert j["canAck"] is False and j["canEdit"] is False


async def test_the_login_page_is_reachable_without_signing_in(client):
    assert (await client.get("/login")).status == 200


async def test_healthz_stays_open(client):
    client.users.upsert("boss", "admin", GOOD)
    assert (await client.get("/healthz")).status in (200, 503)
