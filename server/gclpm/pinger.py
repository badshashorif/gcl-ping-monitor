"""The ping engine.

Uses icmplib's unprivileged mode, which asks the kernel for a SOCK_DGRAM ICMP
socket instead of a raw one. That needs no root and no CAP_NET_RAW - only the
`net.ipv4.ping_group_range` sysctl set in docker-compose.yml. If that sysctl is
missing the socket call fails with EACCES, which is caught and reported once
rather than turning every host red and looking like a total outage.

All hosts are pinged concurrently, so one unreachable host cannot delay the
others: a cycle takes about as long as the slowest single ping, not the sum.
"""

from __future__ import annotations

import asyncio
import logging
import socket

from icmplib import async_ping
from icmplib.exceptions import NameLookupError, SocketPermissionError

from .state import Host

log = logging.getLogger("gclpm.ping")


class Pinger:
    def __init__(self, timeout: float, privileged: bool = False) -> None:
        self.timeout = timeout
        self.privileged = privileged
        self._warned_permission = False
        self._warned_lookup: set[str] = set()

    async def ping_one(self, host: Host) -> float | None:
        """Returns the round-trip time in ms, or None for no reply."""
        try:
            result = await async_ping(
                host.target,
                count=1,
                timeout=self.timeout,
                privileged=self.privileged,
            )
        except SocketPermissionError:
            # One line, once. Repeating it every cycle for every host would
            # bury the actual cause under thousands of identical lines.
            if not self._warned_permission:
                self._warned_permission = True
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
            if host.target not in self._warned_lookup:
                self._warned_lookup.add(host.target)
                log.warning("%s does not resolve", host.target)
            return None
        except (OSError, socket.gaierror) as exc:
            log.debug("ping %s failed: %s", host.target, exc)
            return None
        except Exception as exc:                      # noqa: BLE001
            # Never let one bad host kill the cycle for the other 60.
            log.warning("ping %s raised %s: %s", host.target, type(exc).__name__, exc)
            return None

        if not result.is_alive or result.packets_received == 0:
            return None
        return float(result.avg_rtt)

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
