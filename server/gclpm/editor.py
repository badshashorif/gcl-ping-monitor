"""Editing the host list from a browser.

The rest of config.yml is deliberately NOT editable here. Intervals, SMTP
servers and notification channels are set once and then left alone; the host
list is the part that changes on a Tuesday afternoon when a new router goes in,
and it is the part somebody needs to change from a phone.

Two things this must never do:

  * lose the comments. config.yml is documentation as much as configuration -
    it is what tells the next person what `sound: false` actually means. So the
    file is round-tripped through ruamel rather than re-dumped, and only the
    `hosts:` key is replaced.
  * leave a half-written file behind. A crash mid-write would take the monitor
    down on its next reload, which is exactly when nobody is watching. The new
    text goes to a temporary file in the same directory and is then renamed over
    the old one, which is atomic on Linux, and the previous version is kept as
    config.yml.bak.

Because the file is replaced rather than modified in place, the deployment
mounts the *directory* into the container, not the single file. A single-file
bind mount follows the inode, so the container would go on reading the old,
deleted file for ever and the save would appear to do nothing.
"""

from __future__ import annotations

import ipaddress
import logging
import os
import re
import shutil
from pathlib import Path
from typing import Any

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq

log = logging.getLogger("gclpm.editor")

MAX_HOSTS = 500
MAX_LABEL = 60
MAX_TARGET = 253
MAX_GROUP = 40
MAX_GROUPS = 40

# The bucket for hosts with no group. Never written to the file - it is what
# "you have not said yet" is called on screen, not a group you can join.
UNGROUPED = "Ungrouped"

# Hostnames and IPv4. Anything else - a space, a slash, "http://", a :port - is
# a paste of the wrong thing, and every one of them fails as a DNS lookup that
# never resolves, which on the dashboard is indistinguishable from an outage.
HOST_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$")  # underscores allowed: internal names have them


def valid_target(target: str) -> bool:
    # a colon can only legitimately mean IPv6, so let the stdlib rule on it
    # rather than trying to spell IPv6 out in a regex
    if ":" in target:
        try:
            ipaddress.ip_address(target)
        except ValueError:
            return False
        return True
    return bool(HOST_RE.match(target))


class ValidationError(ValueError):
    """Something in the submitted list is wrong. The message is shown to the
    person editing, so it names the row and says what to do about it."""


def _clean_label(value: Any, fallback: str) -> str:
    text = re.sub(r"[\x00-\x1f\x7f]", "", str(value or "")).strip()
    if not text:
        text = fallback
    return text[:MAX_LABEL]


def _clean_group(value: Any) -> str:
    """A group name, or "" for none.

    Trimmed and control-stripped like a label. "Ungrouped" is folded to "" so
    the reserved on-screen bucket can never become a real group sitting next
    to the genuinely ungrouped hosts.
    """
    text = re.sub(r"[\x00-\x1f\x7f]", "", str(value or "")).strip()[:MAX_GROUP]
    return "" if text.casefold() == UNGROUPED.casefold() else text


def normalise_groups(names: Any, used: list[str] | None = None) -> list[str]:
    """The ordered group list to write, de-duplicated case-insensitively.

    Any group a host names but the list omits is appended rather than
    rejected: the alternative is a save that quietly re-homes a device.
    """
    out: list[str] = []
    seen: set[str] = set()
    for raw in (names if isinstance(names, list) else []):
        name = _clean_group(raw)
        if name and name.casefold() not in seen:
            seen.add(name.casefold())
            out.append(name)
    for name in (used or []):
        if name and name.casefold() not in seen:
            seen.add(name.casefold())
            out.append(name)
    if len(out) > MAX_GROUPS:
        raise ValidationError(f"too many groups ({len(out)}); the limit is {MAX_GROUPS}")
    return out


def normalise(rows: Any) -> list[dict[str, Any]]:
    """Turn whatever the browser posted into the list that will be written.

    Raises ValidationError rather than quietly dropping rows: on a form, a row
    that vanishes on save looks like the save failed, and a host that silently
    stops being monitored is the worst outcome this tool has.
    """
    if not isinstance(rows, list):
        raise ValidationError("expected a list of hosts")
    if len(rows) > MAX_HOSTS:
        raise ValidationError(f"too many hosts ({len(rows)}); the limit is {MAX_HOSTS}")

    out: list[dict[str, Any]] = []
    seen: dict[str, str] = {}

    for i, row in enumerate(rows, start=1):
        if isinstance(row, str):
            row = {"target": row}
        if not isinstance(row, dict):
            raise ValidationError(f"row {i} is not a host")

        target = str(row.get("target", "")).strip()
        if not target:
            raise ValidationError(f"row {i} has no IP or hostname")
        if len(target) > MAX_TARGET:
            raise ValidationError(f"row {i}: '{target[:40]}...' is too long")
        if not valid_target(target):
            raise ValidationError(
                f"row {i}: '{target}' is not a plain IP or hostname "
                "(no spaces, no http://, no port)"
            )

        key = target.lower()
        if key in seen:
            raise ValidationError(
                f"row {i}: {target} is already in the list as '{seen[key]}'. "
                "One device, one row - two rows means two alarms for one outage."
            )
        seen[key] = _clean_label(row.get("label"), target)

        out.append({
            "label": seen[key],
            "target": target,
            "enabled": bool(row.get("enabled", True)),
            "sound": bool(row.get("sound", True)),
            "group": _clean_group(row.get("group")),
        })

    return out


def _to_yaml(rows: list[dict[str, Any]]) -> CommentedSeq:
    """`enabled` and `sound` are written only when they are false.

    Both default to true, so spelling them out on every row would treble the
    length of the file and bury the two lines that actually say something
    unusual about a host. `group` is written whenever there is one.
    """
    seq = CommentedSeq()
    for row in rows:
        item = CommentedMap()
        item["label"] = row["label"]
        item["target"] = row["target"]
        if row.get("group"):
            item["group"] = row["group"]
        if not row["enabled"]:
            item["enabled"] = False
        if not row["sound"]:
            item["sound"] = False
        seq.append(item)
    return seq


def _yaml() -> YAML:
    y = YAML()                      # round-trip mode: comments survive
    y.preserve_quotes = True
    y.width = 4096                  # never fold a long line into something unreadable
    y.indent(mapping=2, sequence=4, offset=2)
    return y


def save_hosts(path: str | os.PathLike[str], rows: Any,
               groups: Any = None) -> tuple[list[dict[str, Any]], list[str]]:
    """Validate and write the host list, and the group order alongside it.

    Returns the normalised hosts and groups. Everything else in the file -
    settings, comments, blank lines - is left exactly as it was.
    """
    hosts = normalise(rows)
    order = normalise_groups(
        groups if groups is not None else [],
        used=[h["group"] for h in hosts if h["group"]],
    )

    # One canonical spelling per group. Without this "CORE_RTR" typed on one
    # row and "core_rtr" on another become two headings holding one layer.
    canon = {name.casefold(): name for name in order}
    for h in hosts:
        if h["group"]:
            h["group"] = canon.get(h["group"].casefold(), h["group"])

    p = Path(path)
    yaml = _yaml()

    with p.open("r", encoding="utf-8") as fh:
        data = yaml.load(fh)
    if data is None:
        data = CommentedMap()
    if not isinstance(data, dict):
        raise ValidationError("config.yml is not a mapping at the top level")

    if order or "groups" in data:
        data["groups"] = CommentedSeq(order)
    data["hosts"] = _to_yaml(hosts)

    tmp = p.parent / (p.name + ".tmp")
    bak = p.parent / (p.name + ".bak")
    try:
        with tmp.open("w", encoding="utf-8", newline="\n") as fh:
            yaml.dump(data, fh)
            fh.flush()
            os.fsync(fh.fileno())
        shutil.copy2(p, bak)        # keep the version we are about to replace
        os.replace(tmp, p)          # atomic: readers see old or new, never half
    except Exception:
        tmp.unlink(missing_ok=True)
        raise

    log.info("config.yml rewritten from the browser: %d host(s), %d group(s)",
             len(hosts), len(order))
    return hosts, order


def read_hosts(path: str | os.PathLike[str]) -> list[dict[str, Any]]:
    """The host list as the editor should show it, straight from the file.

    Read from disk rather than from the running Config so that the form always
    shows what is really saved - including a hand-edit made over SSH a minute
    ago that the ping loop has not picked up yet.
    """
    p = Path(path)
    with p.open("r", encoding="utf-8") as fh:
        data = _yaml().load(fh) or {}
    raw = data.get("hosts") or []
    out: list[dict[str, Any]] = []
    for item in raw:
        if isinstance(item, str):
            item = {"target": item}
        if not isinstance(item, dict):
            continue
        target = str(item.get("target", "")).strip()
        if not target:
            continue
        out.append({
            "label": _clean_label(item.get("label"), target),
            "target": target,
            "enabled": bool(item.get("enabled", True)),
            "sound": bool(item.get("sound", True)),
            "group": _clean_group(item.get("group")),
        })
    return out


def read_groups(path: str | os.PathLike[str]) -> list[str]:
    """The group order as the file has it, plus any group only a host names.

    Same both-ends rule as the running config: a mistyped group must show up
    in the editor as a group, not vanish and take its hosts with it.
    """
    p = Path(path)
    with p.open("r", encoding="utf-8") as fh:
        data = _yaml().load(fh) or {}
    return normalise_groups(
        list(data.get("groups") or []),
        used=[h["group"] for h in read_hosts(path) if h["group"]],
    )
