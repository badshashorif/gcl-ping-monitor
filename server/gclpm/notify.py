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
from dataclasses import dataclass, field
from email.message import EmailMessage

import aiohttp

from .config import Config
from .state import DOWN, Host, fmt_duration

log = logging.getLogger("gclpm.notify")

RED = "\U0001F534"     # large red circle
GREEN = "\U0001F7E2"   # large green circle


CHANNELS = ("email", "telegram", "ntfy")


@dataclass
class Event:
    kind: str            # DOWN | UP
    label: str
    target: str
    at: float
    down_for: str = ""
    key: str = ""                 # host key, for the per-channel bookkeeping
    host: Host | None = None      # the live object: is it STILL down?
    # Channels that have finished with this event - sent it, or decided not
    # to. An event stays queued only while some channel has yet to decide.
    done: set[str] = field(default_factory=set)


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
        # Which hosts each channel has actually been told are down. A channel
        # with a delay must never send a recovery for an outage it was never
        # told about, and must never remind about one either.
        self._announced: dict[str, set[str]] = {c: set() for c in CHANNELS}

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
        return any(n[c]["enabled"] for c in CHANNELS)

    def enabled_channels(self) -> list[str]:
        n = self.cfg.notify
        return [c for c in CHANNELS if n[c]["enabled"]]

    def delay_of(self, channel: str) -> float:
        """Seconds a host must have been down before this channel is told."""
        try:
            return max(0.0, float(self.cfg.notify[channel].get("delay_seconds", 0) or 0))
        except (TypeError, ValueError):
            return 0.0

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
        self.queue.append(Event(kind, host.label, host.target, time.time(),
                                down_for, key=host.key, host=host))

    def _within_cap(self) -> bool:
        cut = time.time() - 3600
        self.sent_times = [t for t in self.sent_times if t > cut]
        cap = int(self.cfg.notify["max_per_hour"])
        if len(self.sent_times) >= cap:
            self.note(f"NOTIFY err: hourly limit ({cap}) reached - message suppressed")
            return False
        self.sent_times.append(time.time())
        return True

    # ---- per-channel delay ---------------------------------------------
    def _pick(self, channel: str, now: float) -> list[Event]:
        """What this channel should be sent right now.

        An event lives in the queue until every channel has finished with it,
        so `e.done` is what stops a fast channel being sent the same event
        again on the next flush while a slow one is still waiting. Events this
        channel decides to skip for good are marked done here; the ones it is
        about to send are marked by the caller, once the send has happened.
        """
        delay = self.delay_of(channel)
        out: list[Event] = []
        for e in self.queue:
            if channel in e.done:
                continue
            if delay <= 0:
                out.append(e)
            elif e.kind == "DOWN":
                if e.host is not None and e.host.status != DOWN:
                    e.done.add(channel)           # recovered inside the window
                elif now - e.at >= delay:
                    out.append(e)                 # down long enough, tell them
                # otherwise: still waiting, leave it undecided
            elif e.key in self._announced[channel]:
                out.append(e)                     # a recovery we owe this channel
            else:
                e.done.add(channel)               # never told it was down
        return out

    # ---- the two things the main loop calls ----------------------------
    async def flush(self) -> None:
        if not self.queue:
            return
        channels = self.enabled_channels()
        if not channels:
            self.queue.clear()
            return

        now = time.time()
        per: dict[str, list[Event]] = {}
        for ch in channels:
            picked = self._pick(ch, now)
            if picked:
                per[ch] = picked
        if not per:
            self._drop_finished(channels)
            return
        # One flush is one message as far as the hourly cap is concerned, even
        # when the channels are carrying different sets of events - otherwise
        # splitting the fan-out would silently triple the send rate.
        if not self._within_cap():
            return

        for ch, events in per.items():
            downs = sum(1 for e in events if e.kind == "DOWN")
            ups = len(events) - downs
            self.note(f"NOTIFY    : sending to {ch} ({downs} down, {ups} up)")
            await self._send(_subject(events, self.monitor),
                             _body(events, self.monitor),
                             _short(events, self.monitor),
                             critical=downs > 0,
                             channels=[ch])
            for e in events:
                e.done.add(ch)
                if e.kind == "DOWN":
                    self._announced[ch].add(e.key)
                else:
                    self._announced[ch].discard(e.key)

        self._drop_finished(channels)
        # any real message restarts the reminder clock, so a fresh outage is
        # never followed seconds later by a "still down" about the same thing
        self.last_sent = time.time()

    def _drop_finished(self, channels: list[str]) -> None:
        """Forget events every enabled channel has finished with."""
        self.queue = [e for e in self.queue
                      if any(ch not in e.done for ch in channels)]

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

        sent_any = False
        for ch in self.enabled_channels():
            # A delayed channel is only reminded about outages it was actually
            # told about. Without this, email at 60s would still get a "STILL
            # DOWN" for a host whose original alert it never received.
            hosts = [h for h in still_down
                     if self.delay_of(ch) <= 0 or h.key in self._announced[ch]]
            if not hosts:
                continue
            events = [
                Event("DOWN", h.label, h.target, time.time(),
                      fmt_duration(time.time() - h.down_since) if h.down_since else "",
                      key=h.key, host=h)
                for h in hosts
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
            self.note(f"NOTIFY    : reminder to {ch} - {len(events)} still down, "
                      "un-acknowledged")
            await self._send(subject, body, short[:300], critical=True, channels=[ch])
            sent_any = True

        if not sent_any:
            # Nothing went out, so do not consume the slot the cap just took.
            if self.sent_times:
                self.sent_times.pop()

    async def send_test(self) -> None:
        e = [Event("DOWN", "TEST-HOST", "0.0.0.0", time.time())]
        self.note("NOTIFY    : test message queued")
        await self._send(f"[TEST] GCL Ping Monitor - {self.monitor}",
                         _body(e, self.monitor),
                         f"[{self.monitor}] GCL Ping Monitor test message",
                         critical=True)

    # ---- channels ------------------------------------------------------
    async def _send(self, subject: str, body: str, short: str, critical: bool,
                    channels: list[str] | None = None) -> None:
        n = self.cfg.notify
        # None means every enabled channel, which is what a test message wants.
        # flush() and reminder() name one channel at a time, because with
        # per-channel delays they no longer all carry the same events.
        want = set(CHANNELS if channels is None else channels)
        tasks = []
        if "email" in want and n["email"]["enabled"]:
            tasks.append(asyncio.to_thread(self._send_email, subject, body))
        if "telegram" in want and n["telegram"]["enabled"]:
            tasks.append(self._send_telegram(body))
        if "ntfy" in want and n["ntfy"]["enabled"]:
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
        # Tapping the notification has to land on the dashboard already
        # authorised. web.public_url + the token does that; click_url is the
        # override for pointing somewhere else entirely.
        click = str(c.get("click_url") or "").strip() or self.cfg.dashboard_url
        if click:
            headers["Click"] = click
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
