"""Email / Telegram / ntfy, with the Windows tool's semantics preserved:

* events inside a batch window become ONE message, so a link failure taking 30
  hosts down does not fire 30 alerts;
* an hourly cap stops an outage storm from becoming an unbounded sender;
* while a host is still down AND un-acknowledged, the alert repeats every
  `repeat_min` minutes. Acknowledging is the off switch.

A silenced host (`sound: false`) still sends. That switch controls noise at the
desk, nothing else.
"""

from __future__ import annotations

import asyncio
import logging
import re
import smtplib
import ssl
import time
from dataclasses import dataclass
from email.message import EmailMessage

import aiohttp

from .config import Config
from .state import Host, fmt_duration

log = logging.getLogger("gclpm.notify")

RED = "\U0001F534"     # large red circle
GREEN = "\U0001F7E2"   # large green circle


@dataclass
class Event:
    kind: str            # DOWN | UP
    label: str
    target: str
    at: float
    down_for: str = ""


def _body(events: list[Event], monitor: str) -> str:
    blocks = []
    for e in events:
        down = e.kind == "DOWN"
        icon = (RED * 2) if down else (GREEN * 2)
        lines = [
            f'{icon} "{e.label}" {"Down" if down else "Up"}',
            f'Severity: {"Critical" if down else "Normal"}',
            f'Timestamp: {time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(e.at))}',
        ]
        if e.target:
            lines.append(f"IP / Host: {e.target}")
        if e.down_for:
            lines.append(f'{"Down for" if down else "Downtime"}: {e.down_for}')
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks) + f"\n\nMonitored from: {monitor}"


def _short(events: list[Event], monitor: str) -> str:
    parts = []
    for e in events:
        p = f'"{e.label}" {"Down" if e.kind == "DOWN" else "Up"}'
        if e.kind == "UP" and e.down_for:
            p += f" (was down {e.down_for})"
        parts.append(p)
    s = f'[{monitor}] {"; ".join(parts)} - {time.strftime("%H:%M:%S")}'
    return s[:297] + "..." if len(s) > 300 else s


def _subject(events: list[Event], monitor: str) -> str:
    downs = [e for e in events if e.kind == "DOWN"]
    ups = [e for e in events if e.kind == "UP"]
    if len(events) == 1:
        tag = "[CRITICAL]" if downs else "[OK]"
        head = f'{tag} "{events[0].label}" {"Down" if downs else "Up"}'
    elif downs and ups:
        head = f"[CRITICAL] {len(downs)} Down, {len(ups)} Up"
    elif downs:
        head = f"[CRITICAL] {len(downs)} host(s) Down"
    else:
        head = f"[OK] {len(ups)} host(s) Up"
    return f"{head} - {monitor}"


class Notifier:
    def __init__(self, cfg: Config, monitor_name: str, note) -> None:
        self.cfg = cfg
        self.monitor = monitor_name
        self.note = note                    # callable(str) -> writes to the log ring
        self.queue: list[Event] = []
        self.sent_times: list[float] = []
        self.last_sent: float | None = None
        self._session: aiohttp.ClientSession | None = None

    async def close(self) -> None:
        if self._session and not self._session.closed:
            await self._session.close()

    async def _http(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=25)
            )
        return self._session

    # ---- queueing ------------------------------------------------------
    @property
    def any_channel(self) -> bool:
        n = self.cfg.notify
        return any(n[c]["enabled"] for c in ("email", "telegram", "ntfy"))

    def add(self, kind: str, host: Host) -> None:
        n = self.cfg.notify
        if not self.any_channel:
            return
        if kind == "DOWN" and not n["on_down"]:
            return
        if kind == "UP" and not n["on_recover"]:
            return
        down_for = ""
        if kind == "UP" and host.down_since:
            down_for = fmt_duration(time.time() - host.down_since)
        self.queue.append(Event(kind, host.label, host.target, time.time(), down_for))

    def _within_cap(self) -> bool:
        cut = time.time() - 3600
        self.sent_times = [t for t in self.sent_times if t > cut]
        cap = int(self.cfg.notify["max_per_hour"])
        if len(self.sent_times) >= cap:
            self.note(f"NOTIFY err: hourly limit ({cap}) reached - message suppressed")
            return False
        self.sent_times.append(time.time())
        return True

    # ---- the two things the main loop calls ----------------------------
    async def flush(self) -> None:
        if not self.queue:
            return
        events, self.queue = self.queue, []
        if not self.any_channel or not self._within_cap():
            return
        downs = sum(1 for e in events if e.kind == "DOWN")
        ups = len(events) - downs
        self.note(f"NOTIFY    : sending ({downs} down, {ups} up)")
        # any real message restarts the reminder clock, so a fresh outage is
        # never followed seconds later by a "still down" about the same thing
        self.last_sent = time.time()
        await self._send(_subject(events, self.monitor),
                         _body(events, self.monitor),
                         _short(events, self.monitor),
                         critical=downs > 0)

    async def reminder(self, still_down: list[Host]) -> None:
        every = int(self.cfg.notify["repeat_min"])
        if every <= 0 or not self.any_channel or not self.cfg.notify["on_down"]:
            return
        if not still_down:
            self.last_sent = None
            return
        if self.last_sent is None:
            self.last_sent = time.time()
            return
        if (time.time() - self.last_sent) < every * 60:
            return
        self.last_sent = time.time()
        if not self._within_cap():
            return

        events = [
            Event("DOWN", h.label, h.target, time.time(),
                  fmt_duration(time.time() - h.down_since) if h.down_since else "")
            for h in still_down
        ]
        if len(events) == 1:
            subject = f'[CRITICAL] "{events[0].label}" STILL DOWN - {self.monitor}'
        else:
            subject = f"[CRITICAL] {len(events)} host(s) STILL DOWN - {self.monitor}"
        body = _body(events, self.monitor) + (
            f"\n\nStill not acknowledged. This repeats every {every} minute(s) "
            "until someone acknowledges it."
        )
        parts = [f'"{e.label}" still down{(" " + e.down_for) if e.down_for else ""}'
                 for e in events]
        short = f'[{self.monitor}] {"; ".join(parts)} - {time.strftime("%H:%M:%S")}'
        self.note(f"NOTIFY    : reminder - {len(events)} still down, un-acknowledged")
        await self._send(subject, body, short[:300], critical=True)

    async def send_test(self) -> None:
        e = [Event("DOWN", "TEST-HOST", "0.0.0.0", time.time())]
        self.note("NOTIFY    : test message queued")
        await self._send(f"[TEST] GCL Ping Monitor - {self.monitor}",
                         _body(e, self.monitor),
                         f"[{self.monitor}] GCL Ping Monitor test message",
                         critical=True)

    # ---- channels ------------------------------------------------------
    async def _send(self, subject: str, body: str, short: str, critical: bool) -> None:
        n = self.cfg.notify
        tasks = []
        if n["email"]["enabled"]:
            tasks.append(asyncio.to_thread(self._send_email, subject, body))
        if n["telegram"]["enabled"]:
            tasks.append(self._send_telegram(body))
        if n["ntfy"]["enabled"]:
            tasks.append(self._send_ntfy(subject, body, critical))
        # one bad channel must not stop the others
        for res in await asyncio.gather(*tasks, return_exceptions=True):
            if isinstance(res, BaseException):
                log.warning("notification channel failed: %s", res)

    def _send_email(self, subject: str, body: str) -> None:
        e = self.cfg.notify["email"]
        rcpts = [a.strip() for a in re.split(r"[;,]", e["to"]) if a.strip()]
        if not rcpts:
            self.note("NOTIFY err: email - no recipient address")
            return
        mode = (e.get("security") or "auto").lower()
        port = int(e["port"])
        if mode == "auto":
            mode = "ssl" if port == 465 else "starttls"
        msg = EmailMessage()
        msg["From"] = e["sender"] or e["user"]
        msg["To"] = ", ".join(rcpts)
        msg["Subject"] = subject
        msg.set_content(body)
        password = self.cfg.secret("email_password")
        try:
            if mode == "ssl":
                # 465 is implicit TLS. It is NOT STARTTLS on another port, and
                # using the wrong one just hangs until it times out.
                ctx = ssl.create_default_context()
                with smtplib.SMTP_SSL(e["smtp_server"], port, timeout=25, context=ctx) as s:
                    if e["user"]:
                        s.login(e["user"], password)
                    s.send_message(msg)
            else:
                with smtplib.SMTP(e["smtp_server"], port, timeout=25) as s:
                    if mode == "starttls":
                        s.starttls(context=ssl.create_default_context())
                    if e["user"]:
                        s.login(e["user"], password)
                    s.send_message(msg)
            self.note(f'NOTIFY    : email sent to {",".join(rcpts)} '
                      f'({e["smtp_server"]}:{port} {mode})')
        except Exception as exc:                       # noqa: BLE001
            self.note(f"NOTIFY err: email - {exc}")

    async def _send_telegram(self, body: str) -> None:
        t = self.cfg.notify["telegram"]
        token = self.cfg.secret("telegram_token")
        if not token or not t["chat_id"]:
            self.note("NOTIFY err: telegram - token or chat_id missing")
            return
        try:
            session = await self._http()
            async with session.post(
                f"https://api.telegram.org/bot{token}/sendMessage",
                data={"chat_id": str(t["chat_id"]),
                      "disable_web_page_preview": "true",
                      "text": body},
            ) as r:
                text = await r.text()
                if r.status != 200:
                    self.note(f"NOTIFY err: telegram - HTTP {r.status} "
                              f"{' '.join(text.split())[:200]}")
                    return
            self.note(f'NOTIFY    : telegram sent to chat {t["chat_id"]}')
        except Exception as exc:                       # noqa: BLE001
            self.note(f"NOTIFY err: telegram - {exc}")

    async def _send_ntfy(self, subject: str, body: str, critical: bool) -> None:
        c = self.cfg.notify["ntfy"]
        topic = str(c["topic"]).strip("/")
        if not topic:
            return
        base = str(c["server"]).rstrip("/") or "https://ntfy.sh"
        pri = int(c["down_priority"] if critical else c["up_priority"])
        if not 1 <= pri <= 5:
            pri = 5 if critical else 3

        # ntfy reads headers as latin-1: the body is UTF-8 and keeps its emoji,
        # the Title must be ASCII or it arrives as mojibake on the phone.
        title = re.sub(r"^\[(CRITICAL|OK)\]\s*", "", subject)
        title = re.sub(r"[^\x20-\x7E]", "?", title)[:90]

        headers = {
            "Title": title,
            "Priority": str(pri),
            "Tags": "rotating_light,warning" if critical else "white_check_mark",
        }
        if c.get("click_url"):
            headers["Click"] = str(c["click_url"])
        token = self.cfg.secret("ntfy_token")
        if token:
            headers["Authorization"] = f"Bearer {token}"

        try:
            session = await self._http()
            async with session.post(
                f"{base}/{topic}",
                data=body.encode("utf-8"),
                headers={**headers, "Content-Type": "text/plain; charset=utf-8"},
            ) as r:
                text = await r.text()
                if r.status >= 300:
                    self.note(f"NOTIFY err: ntfy - HTTP {r.status} "
                              f"{' '.join(text.split())[:200]}")
                    return
            self.note(f"NOTIFY    : ntfy sent to {base}/{topic} (priority {pri})")
        except Exception as exc:                       # noqa: BLE001
            self.note(f"NOTIFY err: ntfy - {exc}")
