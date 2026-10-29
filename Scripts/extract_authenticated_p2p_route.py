#!/usr/bin/env python3

"""Extract a target-bound LAN route from authenticated P2P smoke evidence.

The output is intentionally limited to an address from a still-active,
operator-approved X-Wing session. It is not a generic discovery fallback.
"""

from __future__ import annotations

import argparse
import ipaddress
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


_FIELD_PATTERN = re.compile(r"(?:^|\s)([A-Za-z][A-Za-z0-9]*)=([^\s]+)")
_IPV4_LAN_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)
_IPV6_ULA_NETWORK = ipaddress.ip_network("fc00::/7")


class RouteEvidenceError(ValueError):
    """The status log does not contain a usable authenticated route."""


@dataclass(frozen=True)
class AuthenticatedP2PRoute:
    host: str
    session: str
    remote_device_id: str


def _fields(line: str) -> dict[str, str]:
    return dict(_FIELD_PATTERN.findall(line))


def _canonical_device_id(raw: str | None) -> str | None:
    if raw is None:
        return None
    value = raw.strip().lower()
    if value.startswith("id:"):
        value = value[3:]
    return value or None


def _parse_lan_host(raw: str | None) -> ipaddress.IPv4Address | ipaddress.IPv6Address:
    if raw is None:
        raise RouteEvidenceError("active notice is missing remoteIP")
    value = raw.strip()
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        raise RouteEvidenceError("active notice remoteIP is not an IP literal") from exc

    if isinstance(address, ipaddress.IPv4Address):
        if not any(address in network for network in _IPV4_LAN_NETWORKS):
            raise RouteEvidenceError("active notice remoteIP is not an RFC1918 LAN address")
    elif address not in _IPV6_ULA_NETWORK:
        raise RouteEvidenceError("active notice remoteIP is not an IPv6 ULA address")
    return address


def _session_host(raw: str | None) -> ipaddress.IPv4Address | ipaddress.IPv6Address:
    if raw is None or not raw.startswith("peer:"):
        raise RouteEvidenceError("active notice session is not a peer IP session")
    value = raw.removeprefix("peer:")
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    try:
        return ipaddress.ip_address(value)
    except ValueError as exc:
        raise RouteEvidenceError("active notice session does not contain an IP literal") from exc


def extract_authenticated_p2p_route(
    lines: Iterable[str],
    target_device_id: str,
) -> AuthenticatedP2PRoute:
    status_lines = list(lines)
    canonical_target = _canonical_device_id(target_device_id)
    if canonical_target is None:
        raise RouteEvidenceError("target device id is empty")

    for active_index in range(len(status_lines) - 1, -1, -1):
        line = status_lines[active_index]
        if "remoteControlNoticeActive" not in line:
            continue
        active = _fields(line)
        try:
            if active.get("transport") != "p2p":
                raise RouteEvidenceError("active notice is not P2P")
            if active.get("cryptoSuite") != "X-Wing_PQC":
                raise RouteEvidenceError("active notice is not X-Wing PQC")
            remote_device_id = active.get("remoteDeviceId")
            if _canonical_device_id(remote_device_id) != canonical_target:
                raise RouteEvidenceError("active notice is not bound to the target device id")

            session = active.get("session")
            host = _parse_lan_host(active.get("remoteIP"))
            if _session_host(session) != host:
                raise RouteEvidenceError("active notice session and remoteIP do not match")

            terminal_events = (
                "remoteControlNoticeRejected",
                "remoteControlNoticeTimedOut",
                "remoteControlNoticeDisconnected",
            )
            terminated = any(
                any(event in later_line for event in terminal_events)
                and _fields(later_line).get("session") == session
                for later_line in status_lines[active_index + 1 :]
            )
            if terminated:
                raise RouteEvidenceError("target P2P session has terminal notice evidence")

            established_index: int | None = None
            for candidate_index in range(active_index - 1, -1, -1):
                established_line = status_lines[candidate_index]
                if "mac remote established" not in established_line:
                    continue
                fields = _fields(established_line)
                if fields.get("peer") != session:
                    continue
                if fields.get("suite") != "X-Wing":
                    continue
                if _canonical_device_id(fields.get("remoteDeviceId")) != canonical_target:
                    continue
                established_index = candidate_index
                break
            if established_index is None:
                raise RouteEvidenceError(
                    "active notice has no target-bound X-Wing establishment evidence"
                )

            approved = False
            for approved_line in status_lines[established_index + 1 : active_index]:
                if "remoteControlNoticeApproved" not in approved_line:
                    continue
                fields = _fields(approved_line)
                if fields.get("session") != session or fields.get("transport") != "p2p":
                    continue
                if fields.get("cryptoSuite") != "X-Wing_PQC":
                    continue
                if _canonical_device_id(fields.get("remoteDeviceId")) != canonical_target:
                    continue
                if _parse_lan_host(fields.get("remoteIP")) != host:
                    continue
                approved = True
                break
            if not approved:
                raise RouteEvidenceError(
                    "target-bound X-Wing approval is missing or out of order"
                )

            terminated_before_active = any(
                any(event in candidate_line for event in terminal_events)
                and _fields(candidate_line).get("session") == session
                for candidate_line in status_lines[established_index + 1 : active_index]
            )
            if terminated_before_active:
                raise RouteEvidenceError(
                    "target P2P session terminated before active notice"
                )

            return AuthenticatedP2PRoute(
                host=str(host),
                session=session or "",
                remote_device_id=remote_device_id or "",
            )
        except RouteEvidenceError:
            # The newest Active notice is authoritative. Never revive an older
            # route when a newer active session is invalid, unrelated, or has
            # since terminated.
            raise

    raise RouteEvidenceError("no active P2P security notice evidence")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("status_log", type=Path)
    parser.add_argument("target_device_id")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        with args.status_log.open("r", encoding="utf-8", errors="strict") as handle:
            route = extract_authenticated_p2p_route(handle, args.target_device_id)
    except (OSError, UnicodeError, RouteEvidenceError) as exc:
        print(f"authenticated P2P route unavailable: {exc}", file=sys.stderr)
        return 1
    print(route.host)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
