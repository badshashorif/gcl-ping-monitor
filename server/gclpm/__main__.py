"""Entry point: one asyncio loop running the ping cycle, the notifier and the
web server together."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import getpass
import logging
import os
import signal
import sys
import time

from aiohttp import web as aioweb

from . import config as cfgmod
from .auth import ROLES, AuthError, Users
from .notify import Notifier
from .pinger import Pinger
from .state import Monitor
from .web import Server

VERSION = "1.0.0"

log = logging.getLogger("gclpm")


async def ping_loop(mon: Monitor, cfg_ref: dict, parts: dict) -> None:
    # Latched so a long outage does not repeat the same line every 5 seconds.
    path_warned = False
    while True:
        cfg = cfg_ref["cfg"]
        notifier: Notifier = parts["n"]
        started = time.monotonic()

        if cfgmod.changed_on_disk(cfg):
            try:
                new = cfgmod.load(cfg.path)
            except Exception as exc:                   # noqa: BLE001
                # A syntax error in config.yml must not take the monitor down -
                # keep running on the last good config and say so.
                mon.note(f"CONFIG err: {exc} - keeping the previous configuration")
                cfg.mtime = cfg.path.stat().st_mtime if cfg.path else cfg.mtime
            else:
                cfg_ref["cfg"] = cfg = new
                notifier.cfg = new
                # the web server holds its own reference, and the dashboard
                # reads the monitor name and the read-only flag from it
                if parts.get("s") is not None:
                    parts["s"].cfg = new
                for note in mon.sync(new.hosts, new.loss_window, new.alarm_delay):
                    mon.note(f"CONFIG    : {note}")
                mon.note("CONFIG    : reloaded config.yml")

        if not mon.paused:
            pinger: Pinger = parts["p"]
            pinger.timeout = cfg.timeout
            targets = mon.active()
            probe_started = time.monotonic()
            results = await pinger.ping_all(targets)
            probe_took = time.monotonic() - probe_started
            mon.last_check = time.time()

            # Two lines that decide an argument this tool otherwise cannot
            # settle: when a dozen hosts go red in the same second, is the
            # network broken or is the monitor?
            #
            # A cycle takes about as long as the slowest single ping, because
            # they all run concurrently. If it takes appreciably longer than
            # the timeout then the event loop was blocked, every ping in
            # flight "timed out" for a reason that has nothing to do with the
            # network, and the dashboard is about to show a site-wide outage
            # that never happened.
            if probe_took > cfg.timeout + 0.5:
                mon.note(f"SLOW      : ping cycle took {probe_took:.1f}s for "
                         f"{len(targets)} host(s), timeout is {cfg.timeout:.1f}s "
                         "- misses this cycle may be the monitor, not the hosts")

            # And if most of the list misses in the SAME cycle, these are not
            # that many separate faults. Every target here leaves through one
            # interface and one first hop; that hop is the thing to look at.
            misses = sum(1 for h in targets if results.get(h.key) is None)
            if len(targets) > 2 and misses * 2 > len(targets):
                if not path_warned:
                    path_warned = True
                    mon.note(f"PATH      : {misses} of {len(targets)} hosts missed the "
                             "same cycle - suspect the shared path from this monitor")
            elif path_warned and misses == 0:
                path_warned = False
                mon.note("PATH      : full list answering again")

            for host in targets:
                event = mon.record(host, results.get(host.key), cfg.fail_threshold)
                if event == "DOWN":
                    mon.note(f"DOWN      : {host.label} [{host.target}] - no reply")
                    notifier.add("DOWN", host)
                elif event == "UP":
                    was = ""
                    if host.down_since:
                        from .state import fmt_duration
                        was = f" - was down {fmt_duration(time.time() - host.down_since)}"
                    mon.note(f"RECOVERED : {host.label} [{host.target}]{was}")
                    notifier.add("UP", host)
                    host.down_since = None

        elapsed = time.monotonic() - started
        await asyncio.sleep(max(0.5, cfg.interval - elapsed))


async def notify_loop(mon: Monitor, cfg_ref: dict, parts: dict) -> None:
    while True:
        cfg = cfg_ref["cfg"]
        notifier: Notifier = parts["n"]
        try:
            await notifier.flush()
            await notifier.reminder(mon.unacked_down())
        except Exception as exc:                       # noqa: BLE001
            log.exception("notify loop: %s", exc)
        await asyncio.sleep(max(5, int(cfg.notify["batch_seconds"])))


def build_token(cfg: cfgmod.Config) -> str:
    token = cfg.secret("web_token")
    if not token:
        log.warning("GCLPM_WEB_TOKEN is not set - the dashboard is UNAUTHENTICATED. "
                    "Set it in .env before exposing this to anything.")
    return token


async def amain(args) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s  %(levelname)-7s %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    try:
        cfg = cfgmod.load(args.config)
    except FileNotFoundError:
        log.error("no config at %s", args.config)
        return 2
    except Exception as exc:                           # noqa: BLE001
        log.error("cannot read %s: %s", args.config, exc)
        return 2

    mon = Monitor()
    for note in mon.sync(cfg.hosts, cfg.loss_window, cfg.alarm_delay):
        log.info("config: %s", note)

    cfg_ref = {"cfg": cfg}
    notifier = Notifier(cfg, cfg.monitor_name, mon.note)
    pinger = Pinger(cfg.timeout, privileged=args.privileged)
    parts = {"n": notifier, "p": pinger}

    token = build_token(cfg)
    users = Users(cfg.users_path)
    if users.enabled:
        log.info("accounts are on: %d user(s), the shared link is worth '%s'",
                 len(users.users), cfg.web.get("link_role", "read"))
    server = Server(mon, cfg, token, VERSION,
                    on_ack=lambda: setattr(notifier, "last_sent", None),
                    users=users)
    parts["s"] = server
    app = server.build()

    runner = aioweb.AppRunner(app, access_log=None)
    await runner.setup()
    port = int(cfg.web["port"])
    site = aioweb.TCPSite(runner, "0.0.0.0", port)
    await site.start()

    mon.note(f"MONITOR   : started - v{VERSION} - {len(mon.all())} host(s) loaded")
    log.info("dashboard on http://0.0.0.0:%d/%s",
             port, f"?t={token}" if token else " (NO TOKEN SET)")

    if args.test_notify:
        await notifier.send_test()

    tasks = [
        asyncio.create_task(ping_loop(mon, cfg_ref, parts), name="ping"),
        asyncio.create_task(notify_loop(mon, cfg_ref, parts), name="notify"),
    ]

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, stop.set)

    await stop.wait()
    log.info("shutting down")
    for t in tasks:
        t.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    # send whatever is queued before dying, so an outage that started one second
    # before a restart is not silently swallowed
    with contextlib.suppress(Exception):
        await asyncio.wait_for(notifier.flush(), timeout=20)
    await notifier.close()
    pinger.close()
    await runner.cleanup()
    return 0


def add_user(args) -> int:
    """Create the first admin, or reset a password, from a shell.

    The way in when there is no way in: before any account exists there is
    nobody who can open the Users page, and after a forgotten password there
    is nobody who can reset it.
    """
    try:
        cfg = cfgmod.load(args.config)
    except Exception as exc:                           # noqa: BLE001
        print(f"cannot read {args.config}: {exc}", file=sys.stderr)
        return 2
    if cfg.users_path is None:
        print("this monitor has no config directory to store users in", file=sys.stderr)
        return 2

    password = getpass.getpass(f"password for {args.add_user}: ")
    if password != getpass.getpass("again: "):
        print("they do not match", file=sys.stderr)
        return 2

    users = Users(cfg.users_path)
    try:
        user = users.upsert(args.add_user, args.role, password, actor="cli")
    except AuthError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    existing = len(users.users)
    print(f"{user.name} is now {user.role}. {existing} user(s) in "
          f"{cfg.users_path}.")
    if existing == 1:
        print("Accounts are now ON: the dashboard asks for a password, and the "
              "shared notification link is worth "
              f"'{cfg.web.get('link_role', 'read')}'.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="gclpm", description="GCL Ping Monitor server")
    ap.add_argument("-c", "--config", default=os.environ.get("GCLPM_CONFIG", "/config/config.yml"))
    ap.add_argument("--privileged", action="store_true",
                    help="use raw ICMP sockets (needs root or CAP_NET_RAW). "
                         "The default is unprivileged, which needs only the "
                         "ping_group_range sysctl.")
    ap.add_argument("--test-notify", action="store_true",
                    help="send one test message to every enabled channel at startup")
    ap.add_argument("--add-user", metavar="NAME",
                    help="create or update an account, then exit. The password "
                         "is read from the terminal, never from the command "
                         "line - argv is visible to anyone who can run ps.")
    ap.add_argument("--role", default="admin", choices=list(ROLES),
                    help="the role for --add-user (default: admin)")
    args = ap.parse_args()
    if args.add_user:
        return add_user(args)
    try:
        return asyncio.run(amain(args))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
