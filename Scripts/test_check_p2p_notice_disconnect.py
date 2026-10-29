#!/usr/bin/env python3

from __future__ import annotations

import unittest

from check_p2p_notice_disconnect import NoticeLifecycleError, is_same_session_disconnected


SESSION = "peer:192.168.0.107"


class P2PNoticeDisconnectTests(unittest.TestCase):
    def test_accepts_same_session_disconnect_after_active(self) -> None:
        self.assertTrue(
            is_same_session_disconnected(
                [
                    f"remoteControlNoticeActive session={SESSION} transport=p2p",
                    f"remoteControlNoticeDisconnected session={SESSION} transport=p2p",
                ],
                SESSION,
            )
        )

    def test_unrelated_session_cannot_satisfy_disconnect(self) -> None:
        self.assertFalse(
            is_same_session_disconnected(
                [
                    f"remoteControlNoticeActive session={SESSION} transport=p2p",
                    "remoteControlNoticeDisconnected session=peer:192.168.0.108 transport=p2p",
                ],
                SESSION,
            )
        )

    def test_earlier_disconnect_does_not_satisfy_current_active_session(self) -> None:
        self.assertFalse(
            is_same_session_disconnected(
                [
                    f"remoteControlNoticeDisconnected session={SESSION} transport=p2p",
                    f"remoteControlNoticeActive session={SESSION} transport=p2p",
                ],
                SESSION,
            )
        )

    def test_rejects_duplicate_active_or_disconnected_events(self) -> None:
        for lines in (
            [
                f"remoteControlNoticeActive session={SESSION} transport=p2p",
                f"remoteControlNoticeActive session={SESSION} transport=p2p",
            ],
            [
                f"remoteControlNoticeActive session={SESSION} transport=p2p",
                f"remoteControlNoticeDisconnected session={SESSION} transport=p2p",
                f"remoteControlNoticeDisconnected session={SESSION} transport=p2p",
            ],
        ):
            with self.subTest(lines=lines), self.assertRaises(NoticeLifecycleError):
                is_same_session_disconnected(lines, SESSION)

    def test_rejects_conflicting_terminal_event(self) -> None:
        with self.assertRaisesRegex(NoticeLifecycleError, "conflicting"):
            is_same_session_disconnected(
                [
                    f"remoteControlNoticeActive session={SESSION} transport=p2p",
                    f"remoteControlNoticeTimedOut session={SESSION} transport=p2p",
                    f"remoteControlNoticeDisconnected session={SESSION} transport=p2p",
                ],
                SESSION,
            )

    def test_rejects_missing_active_event(self) -> None:
        with self.assertRaisesRegex(NoticeLifecycleError, "exactly one Active"):
            is_same_session_disconnected(
                [f"remoteControlNoticeDisconnected session={SESSION} transport=p2p"],
                SESSION,
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
