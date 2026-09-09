"""Configuration loading.

Two files on purpose, matching the pattern the other GCL stacks already use:

    config.yml   hosts and behaviour - edited often, safe to read over someone's
                 shoulder, safe to keep in a backup
    .env         secrets only - SMTP password, bot token, ntfy token, the web
                 access token

Keeping them apart means the file people actually edit never contains a
password, so nobody has to think about who can see it.

config.yml is re-read while running: touching it applies the change on the next
cycle, without dropping the ping history or the acknowledgements.
"""

from __future__ import annotations

import os
import copy
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

log = logging.getLogger("gclpm.config")

DEFAULTS: dict[str, Any] = {
    "monitor_name": "",           # blank = use the container/host name
    "interval_seconds": 5,
    "timeout_ms": 1500,
    "fail_threshold": 2,
    "loss_window": 100,
    "web": {
        "port": 8080,
        # Where the dashboard is reachable from a phone, with no token and no
        # trailing slash - e.g. https://ping.example.net. The token is added to
        # it at send time, so a notification can be tapped straight through to
        # the dashboard without config.yml ever holding the secret.
        "public_url": "",
        "allow_ack": True,
        # The browser host editor. Off makes config.yml the only way to change
        # what is monitored - which is what you want once the dashboard link has
        # been handed to people who should only be looking at it.
        "allow_edit": True,
    },
    # How long a host must stay down before the alarm goes off - the red banner
    # and the noise. 0 = the moment it is called DOWN. Raising it lets a link
    # that blips for a few seconds pass without waking the desk, while the
    # phone channels (below) can still be told straight away.
    "alarm": {
        "delay_seconds": 0,
    },
    "notify": {
        "on_down": True,
        "on_recover": True,
        "batch_seconds": 20,
        "max_per_hour": 20,
        "repeat_min": 0,
        # Each channel has its own `delay_seconds`: how long a host must have
        # been down before THAT channel is told. 0 = immediately.
        #
        # The point is to separate a nudge from an escalation. ntfy and Telegram
        # at 0 mean the on-call phone knows within seconds; email at 60 means an
        # inbox that only ever holds real outages, because a host that comes
        # back inside the minute is never mailed about at all - and neither is
        # its recovery, so no orphan "RECOVERED" for a mail nobody received.
        "email": {
            "enabled": False,
            "smtp_server": "",
            "port": 587,
            "security": "auto",   # auto | starttls | ssl | none
            "user": "",
            "sender": "",
            "to": "",
            "delay_seconds": 0,
        },
        "telegram": {
            "enabled": False,
            "chat_id": "",
            "delay_seconds": 0,
        },
        "ntfy": {
            "enabled": False,
            "server": "https://ntfy.sh",
            "topic": "",
            "down_priority": 5,
            "up_priority": 3,
            "click_url": "",
            "delay_seconds": 0,
        },
    },
    "hosts": [],
}

# Every secret comes from the environment, never from config.yml.
SECRET_ENV = {
    "web_token": "GCLPM_WEB_TOKEN",
    "email_password": "GCLPM_EMAIL_PASSWORD",
    "telegram_token": "GCLPM_TELEGRAM_TOKEN",
    "ntfy_token": "GCLPM_NTFY_TOKEN",
}


@dataclass
class HostSpec:
    label: str
    target: str
    enabled: bool = True
    sound: bool = True

    @property
    def key(self) -> str:
        # what identifies a host across a config reload. The target, not the
        # label: renaming a host in config.yml should keep its history and its
        # acknowledgement, and two hosts may legitimately share a label.
        return self.target.strip().lower()


@dataclass
class Config:
    raw: dict[str, Any] = field(default_factory=dict)
    secrets: dict[str, str] = field(default_factory=dict)
    path: Path | None = None
    mtime: float = 0.0

    # ---- plain accessors, so the rest of the code never touches raw dicts ----
    @property
    def interval(self) -> float:
        return max(1.0, float(self.raw["interval_seconds"]))

    @property
    def timeout(self) -> float:
        return max(0.1, float(self.raw["timeout_ms"]) / 1000.0)

    @property
    def fail_threshold(self) -> int:
        return max(1, int(self.raw["fail_threshold"]))

    @property
    def alarm_delay(self) -> float:
        """Seconds a host must stay down before the banner and the noise."""
        try:
            return max(0.0, float(self.raw.get("alarm", {}).get("delay_seconds", 0)))
        except (TypeError, ValueError):
            return 0.0

    @property
    def loss_window(self) -> int:
        return max(5, int(self.raw["loss_window"]))

    @property
    def monitor_name(self) -> str:
        return self.raw.get("monitor_name") or os.uname().nodename

    @property
    def web(self) -> dict[str, Any]:
        return self.raw["web"]

    @property
    def notify(self) -> dict[str, Any]:
        return self.raw["notify"]

    @property
    def hosts(self) -> list[HostSpec]:
        out: list[HostSpec] = []
        seen: set[str] = set()
        for item in self.raw.get("hosts") or []:
            if isinstance(item, str):
                item = {"target": item}
            target = str(item.get("target", "")).strip()
            if not target:
                continue
            spec = HostSpec(
                label=str(item.get("label") or target).strip(),
                target=target,
                enabled=bool(item.get("enabled", True)),
                sound=bool(item.get("sound", True)),
            )
            # A duplicate target would give two rows that can never disagree,
            # two alarms for one outage, and two notifications. Drop the second
            # and say so rather than quietly monitoring it twice.
            if spec.key in seen:
                log.warning("duplicate host %s in config.yml - ignoring the second one", target)
                continue
            seen.add(spec.key)
            out.append(spec)
        return out

    @property
    def dashboard_url(self) -> str:
        """The link to put on a notification, token included.

        Built here rather than written into config.yml, because it has to carry
        the access token and config.yml must never hold a secret. Without the
        token a tapped notification lands on a 401, which is the least useful
        thing a phone can show someone who has just been woken up.
        """
        base = str(self.web.get("public_url", "")).strip().rstrip("/")
        if not base:
            return ""
        token = self.secret("web_token")
        return f"{base}/?t={token}" if token else f"{base}/"

    def secret(self, name: str) -> str:
        return self.secrets.get(name, "")


def _merge(base: dict[str, Any], over: dict[str, Any]) -> dict[str, Any]:
    """Deep-merge `over` onto a copy of `base`, so a config that omits a whole
    section still gets that section's defaults rather than a KeyError later."""
    out = copy.deepcopy(base)
    for key, value in (over or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


def load(path: str | os.PathLike[str]) -> Config:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    parsed = yaml.safe_load(text) or {}
    if not isinstance(parsed, dict):
        raise ValueError("config.yml must be a mapping at the top level")

    raw = _merge(DEFAULTS, parsed)

    # On the public ntfy.sh the topic name IS the password - anyone who knows it
    # can read every alert and send fake ones. So it may come from .env instead,
    # which keeps it out of the file people copy, paste and screenshot.
    topic = os.environ.get("GCLPM_NTFY_TOPIC", "")
    if topic:
        raw["notify"]["ntfy"]["topic"] = topic

    secrets = {name: os.environ.get(env, "") for name, env in SECRET_ENV.items()}

    cfg = Config(raw=raw, secrets=secrets, path=p, mtime=p.stat().st_mtime)
    _warn_about_obvious_mistakes(cfg)
    return cfg


def _warn_about_obvious_mistakes(cfg: Config) -> None:
    n = cfg.notify
    if n["ntfy"]["enabled"] and not n["ntfy"]["topic"]:
        log.warning("ntfy is enabled but no topic is set - nothing will be sent")
    if n["telegram"]["enabled"] and not cfg.secret("telegram_token"):
        log.warning("telegram is enabled but GCLPM_TELEGRAM_TOKEN is empty")
    if n["email"]["enabled"] and not n["email"]["smtp_server"]:
        log.warning("email is enabled but no smtp_server is set")
    if not any(n[c]["enabled"] for c in ("email", "telegram", "ntfy")):
        log.warning("no notification channel is enabled - outages will be visible "
                    "on the dashboard only")
    if not cfg.raw.get("hosts"):
        log.warning("no hosts configured")
    # Enabled-but-nothing-to-do is worth saying out loud: it is exactly the
    # state that looks healthy and monitors nothing.
    if cfg.raw.get("hosts") and not any(h.enabled for h in cfg.hosts):
        log.warning("every host is disabled - nothing is being monitored")


def changed_on_disk(cfg: Config) -> bool:
    if cfg.path is None:
        return False
    try:
        return cfg.path.stat().st_mtime != cfg.mtime
    except OSError:
        return False
