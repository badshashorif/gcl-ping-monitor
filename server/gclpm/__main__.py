"""Entry point: one asyncio loop running the ping cycle, the notifier and the
web server together."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
import os
import signal
import sys
import time

from aiohttp import web as aioweb

from . import config as cfgmod
from .notify import Notifier
from .pinger import Pinger
from .state import Monitor
from .web import Server

VERSION = "1.0.0"

log = logging.getLogger("gclpm")


async def ping_loop(mon: Monitor, cfg_ref: dict, parts: dict) -> None:
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
                for note in mon.sync(new.hosts, new.loss_window):
                    mon.note(f"CONFIG    : {note}")
                mon.note("CONFIG    : reloaded config.yml")

        if not mon.paused:
            pinger: Pinger = parts["p"]
            pinger.timeout = cfg.timeout
            targets = mon.active()
            results = await pinger.ping_all(targets)
            mon.last_check = time.time()

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
    for note in mon.sync(cfg.hosts, cfg.loss_window):
        log.info("config: %s", note)

    cfg_ref = {"cfg": cfg}
    notifier = Notifier(cfg, cfg.monitor_name, mon.note)
    pinger = Pinger(cfg.timeout, privileged=args.privileged)
    parts = {"n": notifier, "p": pinger}

    token = build_token(cfg)
    server = Server(mon, cfg, token, VERSION,
                    on_ack=lambda: setattr(notifier, "last_sent", None))
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
    await runner.cleanup()
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
    args = ap.parse_args()
    try:
        return asyncio.run(amain(args))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
