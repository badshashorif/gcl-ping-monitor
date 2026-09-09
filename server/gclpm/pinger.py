"""The ping engine.

Uses icmplib's unprivileged mode, which asks the kernel for a SOCK_DGRAM ICMP
socket instead of a raw one. That needs no root and no CAP_NET_RAW - only the
`net.ipv4.ping_group_range` sysctl set in docker-compose.yml. If that sysctl is
missing the socket call fails with EACCES, which is caught and reported once
rather than turning every host red and looking like a total outage.

All hosts are pinged concurrently, so one unreachable host cannot delay the
others: a cycle takes about as long as the slowest single ping, not the sum.


Why a thread pool and not asyncio
---------------------------------
This used to be `asyncio.gather(async_ping(...))`. That looked concurrent, but
icmplib's unprivileged path sends each echo request from the event loop one
after another, so the first host's timer was already running while the other
sixteen were still being sent - and that wait landed in its reported RTT.

The symptom was a dashboard whose ms column was a perfect descending staircase
(10,10,10,9,9,9,8,8,8,...): not latency at all, just each host's position in
the send queue. Measured against the same hosts on the same box, 9 Sep 2026:

    plain `ping`                     0.2 - 1.4 ms   (the truth)
    asyncio.gather, count=1          2.5 - 5.2 ms   descending staircase
    thread pool, 3 probes, min_rtt   0.3 - 0.9 ms   matches `ping`

Real threads let the sockets actually run in parallel, so a host's measured
time is its own.


Why three probes and why min_rtt
--------------------------------
One probe is too noisy to publish: a single sample carries the cost of ARP
resolution and of the worker thread starting up. In the same test a lone probe
produced a 227 ms reading for a host that answers in under a millisecond.

`min_rtt` of three is the value least contaminated by scheduling noise, and it
still rises when the path genuinely degrades. It is deliberately not `avg_rtt`
- the point of this change is to stop over-reporting.


Why the probes stop early on failure
------------------------------------
icmplib waits the full timeout for every probe it is asked to send, so asking
for three would cost 3x timeout on a dead host - 4.6s measured against a 1.5s
timeout. The cycle is as slow as its slowest member, so a single dead host
would push every cycle past the 5s poll interval.

So the first probe decides reachability, exactly as one probe did before, and
the extra probes only run once the host has already answered. A dead host
still costs 1x timeout.

Keeping the up/down decision on that first probe also means this change does
not touch alerting behaviour: one lost packet marks a host down today and
still does. Probes 2 and 3 refine the number on the dashboard, nothing else.
"""

from __future__ import annotations

import asyncio
import logging
import socket
import threading
from concurrent.futures import ThreadPoolExecutor

from icmplib import ping as icmp_ping
from icmplib.exceptions import NameLookupError, SocketPermissionError

from .state import Host

log = logging.getLogger("gclpm.ping")

# Enough workers that a normal estate pings in true parallel, capped so a
# runaway config cannot spawn a thread per host without limit. Threads are
# created on demand, so a 17-host install never holds more than 17.
MAX_WORKERS = 128

# Probes per host per cycle, and the gap between them. Three at 50 ms adds
# about 100 ms to a cycle - irrelevant against a 5s interval.
PROBES = 3
PROBE_INTERVAL = 0.05


class Pinger:
    def __init__(
        self,
        timeout: float,
        privileged: bool = False,
        probes: int = PROBES,
        probe_interval: float = PROBE_INTERVAL,
        max_workers: int = MAX_WORKERS,
    ) -> None:
        self.timeout = timeout
        self.privileged = privileged
        self.probes = max(1, int(probes))
        self.probe_interval = probe_interval
        self._warned_permission = False
        self._warned_lookup: set[str] = set()
        # The warn-once flags are now touched from worker threads, so the
        # check-and-set has to be atomic or the "once" becomes "sometimes
        # twice".
        self._warn_lock = threading.Lock()
        self._pool = ThreadPoolExecutor(
            max_workers=max(1, int(max_workers)),
            thread_name_prefix="gclpm-ping",
        )

    # -- the blocking half, run on a worker thread ---------------------------

    def _probe(self, target: str) -> float | None:
        """One icmplib call. Returns min RTT in ms, or None for no reply."""
        try:
            result = icmp_ping(
                target,
                count=1,
                timeout=self.timeout,
                privileged=self.privileged,
            )
        except SocketPermissionError:
            # One line, once. Repeating it every cycle for every host would
            # bury the actual cause under thousands of identical lines.
            with self._warn_lock:
                first = not self._warned_permission
                self._warned_permission = True
            if first:
                log.error(
                    "cannot open an ICMP socket. The container needs "
                    "sysctls: net.ipv4.ping_group_range = '0 2147483647' "
                    "(or cap_add: NET_RAW with privileged pings)."
                )
            return None
        except NameLookupError:
            # A name that does not resolve is genuinely down as far as this
            # tool is concerned, but it is worth distinguishing in the log the
            # first time - "no such host" and "no reply" have different fixes.
            with self._warn_lock:
                first = target not in self._warned_lookup
                self._warned_lookup.add(target)
            if first:
                log.warning("%s does not resolve", target)
            return None
        except (OSError, socket.gaierror) as exc:
            log.debug("ping %s failed: %s", target, exc)
            return None
        except Exception as exc:                      # noqa: BLE001
            # Never let one bad host kill the cycle for the other 60.
            log.warning("ping %s raised %s: %s", target, type(exc).__name__, exc)
            return None

        if not result.is_alive or result.packets_received == 0:
            return None
        return float(result.min_rtt)

    def _measure(self, target: str) -> float | None:
        """First probe decides reachability; the rest only sharpen the number.

        Returns the best RTT seen, or None if the host did not answer at all.
        """
        best = self._probe(target)
        if best is None:
            return None                     # dead: one timeout, not `probes`
        for _ in range(self.probes - 1):
            if self.probe_interval:
                # A plain sleep on a worker thread - the event loop is free.
                threading.Event().wait(self.probe_interval)
            rtt = self._probe(target)
            if rtt is not None and rtt < best:
                best = rtt
        return best

    # -- the async half, what the poll loop calls ----------------------------

    async def ping_one(self, host: Host) -> float | None:
        """Returns the round-trip time in ms, or None for no reply."""
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self._pool, self._measure, host.target)

    async def ping_all(self, hosts: list[Host]) -> dict[str, float | None]:
        if not hosts:
            return {}
        results = await asyncio.gather(
            *(self.ping_one(h) for h in hosts),
            return_exceptions=True,
        )
        out: dict[str, float | None] = {}
        for host, res in zip(hosts, results):
            if isinstance(res, BaseException):
                log.warning("ping %s raised %s", host.target, res)
                out[host.key] = None
            else:
                out[host.key] = res
        return out

    def resolves_ok(self) -> bool:
        return not self._warned_permission

    def close(self) -> None:
        """Let the worker threads finish and go away. Safe to call twice."""
        self._pool.shutdown(wait=False)
