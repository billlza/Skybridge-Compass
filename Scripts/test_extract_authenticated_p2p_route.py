#!/usr/bin/env python3

from __future__ import annotations

import unittest

from extract_authenticated_p2p_route import (
    RouteEvidenceError,
    extract_authenticated_p2p_route,
)


TARGET = "9DDF920E-D7C4-51F2-9C94-67FF629BDF04"
SESSION = "peer:192.168.0.107"


def valid_lines() -> list[str]:
    return [
        f"mac remote established peer={SESSION} remoteDeviceId=id:{TARGET.lower()} suite=X-Wing",
        (
            f"remoteControlNoticeApproved session={SESSION} transport=p2p "
            f"remoteIP=192.168.0.107 remoteDeviceId={TARGET} cryptoSuite=X-Wing_PQC"
        ),
        (
            f"remoteControlNoticeActive session={SESSION} transport=p2p "
            f"remoteIP=192.168.0.107 remoteDeviceId={TARGET} cryptoSuite=X-Wing_PQC"
        ),
    ]


class AuthenticatedP2PRouteTests(unittest.TestCase):
    def test_extracts_target_bound_active_lan_route(self) -> None:
        route = extract_authenticated_p2p_route(valid_lines(), TARGET)

        self.assertEqual(route.host, "192.168.0.107")
        self.assertEqual(route.session, SESSION)

    def test_rejects_notice_for_a_different_target(self) -> None:
        lines = valid_lines()
        lines[-1] = lines[-1].replace(TARGET, "11111111-1111-1111-1111-111111111111")

        with self.assertRaisesRegex(RouteEvidenceError, "target device id"):
            extract_authenticated_p2p_route(lines, TARGET)

    def test_rejects_establishment_without_target_binding(self) -> None:
        lines = valid_lines()
        lines[0] = f"mac remote established peer={SESSION} suite=X-Wing"

        with self.assertRaisesRegex(RouteEvidenceError, "establishment evidence"):
            extract_authenticated_p2p_route(lines, TARGET)

    def test_rejects_wrong_established_suite(self) -> None:
        lines = valid_lines()
        lines[0] = lines[0].replace("suite=X-Wing", "suite=ML-KEM-768")

        with self.assertRaisesRegex(RouteEvidenceError, "establishment evidence"):
            extract_authenticated_p2p_route(lines, TARGET)

    def test_rejects_public_and_link_local_addresses(self) -> None:
        for host in ("203.0.113.7", "169.254.8.9", "fe80::1"):
            with self.subTest(host=host):
                session = f"peer:{host}"
                lines = [
                    f"mac remote established peer={session} remoteDeviceId={TARGET} suite=X-Wing",
                    (
                        f"remoteControlNoticeApproved session={session} transport=p2p "
                        f"remoteIP={host} remoteDeviceId={TARGET} cryptoSuite=X-Wing_PQC"
                    ),
                    (
                        f"remoteControlNoticeActive session={session} transport=p2p "
                        f"remoteIP={host} remoteDeviceId={TARGET} cryptoSuite=X-Wing_PQC"
                    ),
                ]
                with self.assertRaises(RouteEvidenceError):
                    extract_authenticated_p2p_route(lines, TARGET)

    def test_rejects_mismatched_session_address(self) -> None:
        lines = valid_lines()
        lines[-1] = lines[-1].replace("remoteIP=192.168.0.107", "remoteIP=192.168.0.108")

        with self.assertRaisesRegex(RouteEvidenceError, "do not match"):
            extract_authenticated_p2p_route(lines, TARGET)

    def test_rejects_session_disconnected_after_active_notice(self) -> None:
        lines = valid_lines() + [
            f"remoteControlNoticeDisconnected session={SESSION} transport=p2p"
        ]

        with self.assertRaisesRegex(RouteEvidenceError, "terminal notice"):
            extract_authenticated_p2p_route(lines, TARGET)

    def test_rejects_approval_before_xwing_establishment(self) -> None:
        lines = valid_lines()
        lines[0], lines[1] = lines[1], lines[0]

        with self.assertRaisesRegex(RouteEvidenceError, "out of order"):
            extract_authenticated_p2p_route(lines, TARGET)

    def test_rejects_session_rejected_before_active_notice(self) -> None:
        lines = valid_lines()
        lines.insert(
            -1,
            f"remoteControlNoticeRejected session={SESSION} transport=p2p",
        )

        with self.assertRaisesRegex(RouteEvidenceError, "terminated before active"):
            extract_authenticated_p2p_route(lines, TARGET)

    def test_rejects_approved_notice_that_never_became_active(self) -> None:
        lines = valid_lines()
        lines[-1] = lines[-1].replace("remoteControlNoticeActive", "remoteControlNoticeApproved")

        with self.assertRaisesRegex(RouteEvidenceError, "no active"):
            extract_authenticated_p2p_route(lines, TARGET)

    def test_does_not_revive_older_target_when_newer_session_is_active(self) -> None:
        other_target = "11111111-1111-1111-1111-111111111111"
        other_session = "peer:192.168.0.108"
        lines = valid_lines() + [
            f"mac remote established peer={other_session} remoteDeviceId={other_target} suite=X-Wing",
            (
                f"remoteControlNoticeApproved session={other_session} transport=p2p "
                f"remoteIP=192.168.0.108 remoteDeviceId={other_target} cryptoSuite=X-Wing_PQC"
            ),
            (
                f"remoteControlNoticeActive session={other_session} transport=p2p "
                f"remoteIP=192.168.0.108 remoteDeviceId={other_target} cryptoSuite=X-Wing_PQC"
            ),
        ]

        with self.assertRaisesRegex(RouteEvidenceError, "target device id"):
            extract_authenticated_p2p_route(lines, TARGET)


if __name__ == "__main__":
    unittest.main()
