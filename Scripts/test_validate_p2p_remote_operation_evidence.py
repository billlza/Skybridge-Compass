#!/usr/bin/env python3

import unittest

from validate_p2p_remote_operation_evidence import (
    EvidenceValidationError,
    validate_remote_operation,
)


SESSION_A = "ev1:11111111111111111111111111111111"
SESSION_B = "ev1:22222222222222222222222222222222"
STREAM_A = "ev1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
STREAM_B = "ev1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PIB_A = "ev1:cccccccccccccccccccccccccccccccc"
SKR_A = "ev1:dddddddddddddddddddddddddddddddd"
PAYLOAD_A = "ev1:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"


def ios_evidence(session: str = SESSION_A, stream: str = STREAM_A) -> list[str]:
    return [
        f"PIB-1 protocol identity binding request: pib_ref={PIB_A}",
        f"SKR-1 signed LAN KEM refresh request: skr_ref={SKR_A}",
        f"SKR-1 signed LAN KEM refresh verified and imported: payload_ref={PAYLOAD_A}",
        f"p2p-evidence-link session_ref={session} pib_ref={PIB_A} skr_ref={SKR_A} payload_ref={PAYLOAD_A}",
        f"p2p-session-link session_ref={session}",
        f"event=streamConfigSent session_ref={session} stream_ref={stream} perf=extreme",
        f"event=streamConfigAck session_ref={session} stream_ref={stream}",
        f"event=firstFrame session_ref={session} stream_ref={stream}",
    ]


def host_evidence(session: str = SESSION_A, stream: str = STREAM_A) -> list[str]:
    return [
        f"PIB-1 protocol identity binding served: pib_ref={PIB_A}",
        f"SKR-1 signed LAN KEM refresh served: skr_ref={SKR_A} payload_ref={PAYLOAD_A}",
        f"mac-stream-config peer=redacted session_ref={session} stream_ref={stream}",
        f"mac-stream-config-ack session_ref={session} stream_ref={stream}",
        f"mac-remote-frame-tx session_ref={session} stream_ref={stream} sent=1",
    ]


class P2PRemoteOperationEvidenceTests(unittest.TestCase):
    def test_accepts_one_exact_ordered_operation(self) -> None:
        self.assertEqual(
            validate_remote_operation(host_evidence(), ios_evidence()),
            (SESSION_A, STREAM_A),
        )

    def test_rejects_cross_session_join(self) -> None:
        with self.assertRaises(EvidenceValidationError):
            validate_remote_operation(host_evidence(SESSION_B), ios_evidence())

    def test_rejects_cross_stream_join(self) -> None:
        lines = ios_evidence()
        lines[-1] = (
            f"event=firstFrame session_ref={SESSION_A} stream_ref={STREAM_B}"
        )
        with self.assertRaises(EvidenceValidationError):
            validate_remote_operation(host_evidence(), lines)

    def test_rejects_first_frame_before_ack(self) -> None:
        lines = ios_evidence()
        lines[-2], lines[-1] = lines[-1], lines[-2]
        with self.assertRaises(EvidenceValidationError):
            validate_remote_operation(host_evidence(), lines)

    def test_rejects_pre_ack_frame_even_when_a_later_frame_would_pass(self) -> None:
        lines = ios_evidence()
        lines.insert(
            -2,
            f"event=firstFrame session_ref={SESSION_A} stream_ref={STREAM_A}",
        )
        with self.assertRaises(EvidenceValidationError):
            validate_remote_operation(host_evidence(), lines)

    def test_rejects_pre_ack_mac_transmit_even_when_a_later_transmit_would_pass(self) -> None:
        lines = host_evidence()
        lines.insert(
            -2,
            f"mac-remote-frame-tx session_ref={SESSION_A} stream_ref={STREAM_A} sent=1",
        )
        with self.assertRaises(EvidenceValidationError):
            validate_remote_operation(lines, ios_evidence())

    def test_rejects_ambiguous_initial_attempts(self) -> None:
        lines = ios_evidence() + [
            f"event=streamConfigSent session_ref={SESSION_B} stream_ref={STREAM_B} perf=extreme"
        ]
        with self.assertRaises(EvidenceValidationError):
            validate_remote_operation(host_evidence(), lines)

    def test_rejects_malformed_reference(self) -> None:
        lines = ios_evidence()
        lines[-3] = (
            f"event=streamConfigSent session_ref=not-a-ref stream_ref={STREAM_A} perf=extreme"
        )
        with self.assertRaises(EvidenceValidationError):
            validate_remote_operation(host_evidence(), lines)

    def test_rejects_approval_from_another_session(self) -> None:
        with self.assertRaises(EvidenceValidationError):
            validate_remote_operation(
                host_evidence(),
                ios_evidence(),
                approval_proof={
                    "schemaVersion": 2,
                    "sessionRef": SESSION_B,
                    "humanApproval": True,
                    "runtimeAutoApproval": False,
                },
            )

    def test_functional_lane_can_skip_fresh_identity_link_but_not_session_link(self) -> None:
        ios_lines = [
            line
            for line in ios_evidence()
            if "p2p-evidence-link " not in line
            and "PIB-1 " not in line
            and "SKR-1 " not in line
        ]
        host_lines = [
            line
            for line in host_evidence()
            if "PIB-1 " not in line and "SKR-1 " not in line
        ]
        self.assertEqual(
            validate_remote_operation(
                host_lines,
                ios_lines,
                require_identity_link=False,
            ),
            (SESSION_A, STREAM_A),
        )


if __name__ == "__main__":
    unittest.main()
