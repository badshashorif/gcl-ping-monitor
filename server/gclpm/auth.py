"""Users, passwords and what each of them is allowed to do.

Three roles, and the difference between them is the blast radius:

    read    look at the dashboard. Nothing else.
    write   acknowledge, and change what is monitored - hosts and groups.
    admin   all of that, plus the user list itself.

Two deliberate decisions worth knowing before changing anything here.

**Nothing changes until you opt in.** With no `users.yml` the tool behaves
exactly as it always has: the link token is the only lock and it grants full
access. The moment the file exists with a user in it, a password is required.
An upgrade that silently locked everybody out of a monitoring dashboard would
be the worst possible way to improve its security.

**The notification link still works.** Tapping an ntfy alert at 3am has to
land on the dashboard, not on a login form - so the shared token keeps
working, at whatever role `web.link_role` says. It defaults to `read`: enough
to see what woke you, not enough to change the estate from a phone somebody
else could be holding.

Passwords are scrypt hashes in `config/users.yml`, which lives in the mounted
config directory - already gitignored, and never in the image. They are never
logged, never returned by the API, and never accepted on a command line where
`ps` would show them.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import os
import re
import secrets
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ruamel.yaml import YAML

log = logging.getLogger("gclpm.auth")

ROLES = ("read", "write", "admin")
RANK = {"read": 0, "write": 1, "admin": 2}

# scrypt, not a plain digest: the point of a password hash is to be slow.
# n=16384 costs roughly 16 MB and a few ms, which is nothing for one login a
# day and a great deal for someone working through a stolen file.
SCRYPT_N, SCRYPT_R, SCRYPT_P, DKLEN = 1 << 14, 8, 1, 32

MAX_USERS = 50
MIN_PASSWORD = 10
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{1,31}$")

SESSION_HOURS = 12
# Failed logins back off, so a stolen username is not a free guessing budget.
# Deliberately in-process and per-username rather than a firewall rule:
# enumerating usernames against this box once tripped fail2ban and locked the
# real operator out, which is a worse outcome than a slow attacker.
LOCK_AFTER = 5
LOCK_SECONDS = 60


class AuthError(ValueError):
    """Something the person can see and fix. The message is shown to them."""


# ---- passwords -------------------------------------------------------------
def hash_password(password: str) -> str:
    if not isinstance(password, str) or len(password) < MIN_PASSWORD:
        raise AuthError(f"a password needs at least {MIN_PASSWORD} characters")
    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=SCRYPT_N,
                        r=SCRYPT_R, p=SCRYPT_P, dklen=DKLEN)
    return "scrypt${}${}${}${}${}".format(
        SCRYPT_N, SCRYPT_R, SCRYPT_P,
        base64.b64encode(salt).decode(), base64.b64encode(dk).decode())


def verify_password(stored: str, password: str) -> bool:
    try:
        kind, n, r, p, salt_b64, dk_b64 = str(stored).split("$")
        if kind != "scrypt":
            return False
        dk = hashlib.scrypt(password.encode("utf-8"),
                            salt=base64.b64decode(salt_b64),
                            n=int(n), r=int(r), p=int(p),
                            dklen=len(base64.b64decode(dk_b64)))
    except (ValueError, TypeError, MemoryError):
        return False
    return hmac.compare_digest(dk, base64.b64decode(dk_b64))


# A hash of nothing anybody knows. Verified against when the username does not
# exist, so a wrong name and a wrong password take the same time to refuse -
# otherwise the login form answers "does this user exist?" for free.
_DECOY = hash_password(secrets.token_urlsafe(24))


@dataclass
class User:
    name: str
    role: str
    password: str = ""          # the hash. Never leaves the process.

    def can(self, need: str) -> bool:
        return RANK.get(self.role, -1) >= RANK[need]

    def public(self) -> dict[str, str]:
        return {"name": self.name, "role": self.role}


def _clean_name(value: Any) -> str:
    name = str(value or "").strip().lower()
    if not NAME_RE.match(name):
        raise AuthError(
            "a username is 2-32 characters, lowercase letters, digits, dot, "
            "dash or underscore, starting with a letter or digit")
    return name


def _clean_role(value: Any) -> str:
    role = str(value or "").strip().lower()
    if role not in ROLES:
        raise AuthError(f"role must be one of {', '.join(ROLES)}")
    return role


def _yaml() -> YAML:
    y = YAML()
    y.preserve_quotes = True
    y.width = 4096
    y.indent(mapping=2, sequence=4, offset=2)
    return y


class Users:
    """The user list, backed by config/users.yml.

    Re-read whenever the file changes, the same way config.yml is, so adding
    a user over SSH does not need a restart.
    """

    def __init__(self, path: str | os.PathLike[str] | None):
        self.path = Path(path) if path else None
        self.users: dict[str, User] = {}
        self.mtime: float = -1.0
        self._fails: dict[str, tuple[int, float]] = {}
        self.reload()

    # ---- the opt-in switch ---------------------------------------------
    @property
    def enabled(self) -> bool:
        """Auth is on only once there is somebody to log in as. An empty or
        missing file means the tool works exactly as it did before."""
        return bool(self.users)

    def reload(self) -> bool:
        if self.path is None or not self.path.exists():
            changed = bool(self.users)
            self.users, self.mtime = {}, -1.0
            return changed
        try:
            mtime = self.path.stat().st_mtime
        except OSError:
            return False
        if mtime == self.mtime:
            return False
        try:
            with self.path.open("r", encoding="utf-8") as fh:
                data = _yaml().load(fh) or {}
            found: dict[str, User] = {}
            for item in data.get("users") or []:
                if not isinstance(item, dict):
                    continue
                name = str(item.get("name", "")).strip().lower()
                role = str(item.get("role", "")).strip().lower()
                if not name or role not in ROLES:
                    log.warning("users.yml: skipping a row with no name or a bad role")
                    continue
                found[name] = User(name=name, role=role,
                                   password=str(item.get("password", "")))
            self.users, self.mtime = found, mtime
            log.info("users.yml loaded: %d user(s)", len(found))
            return True
        except Exception:                                    # noqa: BLE001
            # A broken user file must not take the monitor down, and must not
            # silently drop everyone's access either - keep the last good list.
            log.exception("users.yml could not be read - keeping the previous list")
            return False

    # ---- logging in ------------------------------------------------------
    def locked_for(self, name: str) -> float:
        count, until = self._fails.get(name, (0, 0.0))
        return max(0.0, until - time.time())

    def check(self, name: Any, password: Any) -> User:
        """Return the user, or raise AuthError. Never says which half was
        wrong: "no such user" is a free answer to a question nobody should be
        allowed to ask."""
        key = str(name or "").strip().lower()
        wait = self.locked_for(key)
        if wait > 0:
            raise AuthError(f"too many attempts - try again in {int(wait) + 1}s")

        user = self.users.get(key)
        ok = verify_password(user.password if user else _DECOY,
                             str(password or ""))
        if not ok or user is None:
            count, _ = self._fails.get(key, (0, 0.0))
            count += 1
            until = time.time() + LOCK_SECONDS if count >= LOCK_AFTER else 0.0
            self._fails[key] = (count, until)
            if until:
                log.warning("login: %s locked out for %ds after %d failures",
                            key or "(blank)", LOCK_SECONDS, count)
            raise AuthError("wrong username or password")

        self._fails.pop(key, None)
        return user

    # ---- managing them ---------------------------------------------------
    def list(self) -> list[dict[str, str]]:
        return [self.users[n].public() for n in sorted(self.users)]

    def upsert(self, name: Any, role: Any, password: Any = None,
               actor: str = "") -> User:
        key = _clean_name(name)
        want = _clean_role(role)
        existing = self.users.get(key)

        if existing is None and not password:
            raise AuthError("a new user needs a password")

        # The last admin must not be able to demote themselves into a system
        # nobody can administer. Recoverable only by editing the file by hand,
        # which is exactly the 3am job worth designing out.
        if existing is not None and existing.role == "admin" and want != "admin":
            if sum(1 for u in self.users.values() if u.role == "admin") == 1:
                raise AuthError("this is the only admin - promote someone else first")

        user = User(name=key, role=want,
                    password=hash_password(password) if password
                    else (existing.password if existing else ""))
        self.users[key] = user
        if len(self.users) > MAX_USERS:
            self.users.pop(key)
            raise AuthError(f"too many users; the limit is {MAX_USERS}")
        self.save()
        log.info("user %s %s as %s%s", key,
                 "updated" if existing else "created", want,
                 f" by {actor}" if actor else "")
        return user

    def remove(self, name: Any, actor: str = "") -> None:
        key = str(name or "").strip().lower()
        if key not in self.users:
            raise AuthError(f"no user called {key}")
        if self.users[key].role == "admin" and \
                sum(1 for u in self.users.values() if u.role == "admin") == 1:
            raise AuthError("this is the only admin - make someone else one first")
        del self.users[key]
        self.save()
        log.info("user %s removed%s", key, f" by {actor}" if actor else "")

    def save(self) -> None:
        if self.path is None:
            raise AuthError("there is nowhere to save users on this monitor")
        data = {"users": [{"name": u.name, "role": u.role, "password": u.password}
                          for u in (self.users[n] for n in sorted(self.users))]}
        tmp = self.path.parent / (self.path.name + ".tmp")
        bak = self.path.parent / (self.path.name + ".bak")
        try:
            # 600 before a single byte of hash is written, not after
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
                fh.write("# GCL Ping Monitor - users. scrypt hashes, never "
                         "plaintext.\n# Managed from the dashboard; safe to "
                         "edit by hand. NEVER commit this file.\n")
                _yaml().dump(data, fh)
                fh.flush()
                os.fsync(fh.fileno())
            if self.path.exists():
                shutil.copy2(self.path, bak)
                os.chmod(bak, 0o600)
            os.replace(tmp, self.path)
        except Exception:
            Path(tmp).unlink(missing_ok=True)
            raise
        self.mtime = self.path.stat().st_mtime


class Sessions:
    """Login sessions, in memory.

    Not persisted on purpose: a redeploy asking people to log in again is a
    mild annoyance, whereas a session file is one more thing holding the keys
    to the estate on disk. The notification link is unaffected - it carries
    its own token and never needed a session.
    """

    def __init__(self, hours: float = SESSION_HOURS):
        self.ttl = max(0.25, float(hours)) * 3600.0
        self._live: dict[str, tuple[str, float]] = {}

    def new(self, user: User) -> str:
        self._sweep()
        token = secrets.token_urlsafe(32)
        self._live[token] = (user.name, time.time() + self.ttl)
        return token

    def user_of(self, token: str, users: Users) -> User | None:
        if not token:
            return None
        row = self._live.get(token)
        if row is None:
            return None
        name, expires = row
        if expires < time.time():
            self._live.pop(token, None)
            return None
        # The role is read fresh every request, so demoting somebody takes
        # effect at once instead of when their session happens to expire.
        return users.users.get(name)

    def drop(self, token: str) -> None:
        self._live.pop(token, None)

    def drop_user(self, name: str) -> None:
        """Removing or demoting a user must not leave their session usable."""
        for token in [t for t, (n, _) in self._live.items() if n == name]:
            self._live.pop(token, None)

    def _sweep(self) -> None:
        now = time.time()
        for token in [t for t, (_, e) in self._live.items() if e < now]:
            self._live.pop(token, None)
