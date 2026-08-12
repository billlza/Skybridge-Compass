#!/usr/bin/env python3
"""Focused behavior tests for the vendored physical-iOS ownership helper."""

from __future__ import annotations

import importlib.util
import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "lib/webrtc_smoke_process_ownership.py"
SPEC = importlib.util.spec_from_file_location("process_ownership", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
ownership = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ownership
SPEC.loader.exec_module(ownership)


class ProcessOwnershipTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.app = self.root / "SkyBridgeCompass-iOS.app"
        self.app.mkdir()
        with (self.app / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleExecutable": "SkyBridgeCompass-iOS"}, handle)
        executable = self.app / "SkyBridgeCompass-iOS"
        executable.write_bytes(b"fixture")
        executable.chmod(0o700)
        self.pid = 4321
        self.audit_token = [0, 1, 2, 3, 4, self.pid, 6, 7]
        self.runtime_url = (
            "file:///private/var/containers/Bundle/Application/ABC/"
            "SkyBridgeCompass-iOS.app/SkyBridgeCompass-iOS"
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def private_text(self, name: str, contents: str) -> Path:
        path = self.root / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o600)
        return path

    def private_json(self, name: str, payload: object) -> Path:
        return self.private_text(name, json.dumps(payload))

    def launch_payload(self) -> dict[str, object]:
        return {
            "result": {
                "process": {
                    "auditToken": self.audit_token,
                    "executable": self.runtime_url,
                    "processIdentifier": self.pid,
                }
            }
        }

    def test_ios_capture_binds_pid_audit_token_and_bundle_executable(self) -> None:
        launch = self.private_json("launch.json", self.launch_payload())
        output = self.root / "identity.json"

        ownership.ios_capture(launch, self.app, output)

        identity = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(identity["processIdentifier"], self.pid)
        self.assertEqual(identity["auditToken"], self.audit_token)
        self.assertTrue(identity["executablePath"].endswith(
            "/SkyBridgeCompass-iOS.app/SkyBridgeCompass-iOS"
        ))
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_private_json_rejects_duplicate_nested_keys(self) -> None:
        launch = self.private_text(
            "duplicate.json",
            '{"result":{"process":{"processIdentifier":1,"processIdentifier":2}}}',
        )
        with self.assertRaisesRegex(ownership.OwnershipError, "duplicate key"):
            ownership._read_private_json(launch)

    def test_private_json_rejects_non_finite_numbers(self) -> None:
        launch = self.private_text("nan.json", '{"result":{"value":NaN}}')
        with self.assertRaisesRegex(ownership.OwnershipError, "non-finite number"):
            ownership._read_private_json(launch)

    def test_ios_capture_rejects_audit_token_pid_mismatch(self) -> None:
        payload = self.launch_payload()
        process = payload["result"]["process"]  # type: ignore[index]
        process["auditToken"] = [0, 1, 2, 3, 4, self.pid + 1, 6, 7]  # type: ignore[index]
        launch = self.private_json("mismatch.json", payload)
        with self.assertRaisesRegex(ownership.OwnershipError, "bound to its process identifier"):
            ownership.ios_capture(launch, self.app, self.root / "identity.json")

    def test_ios_capture_rejects_invalid_or_noncanonical_percent_encoding(self) -> None:
        for suffix in ("%ZZ", "%53kyBridgeCompass-iOS"):
            with self.subTest(suffix=suffix):
                payload = self.launch_payload()
                process = payload["result"]["process"]  # type: ignore[index]
                process["executable"] = (  # type: ignore[index]
                    "file:///private/var/containers/Bundle/Application/ABC/"
                    f"{suffix}.app/SkyBridgeCompass-iOS"
                )
                launch = self.private_json(f"invalid-{suffix.replace('%', '')}.json", payload)
                with self.assertRaisesRegex(
                    ownership.OwnershipError,
                    "(invalid URL encoding|not canonically percent-encoded)",
                ):
                    ownership.ios_capture(launch, self.app, self.root / "identity.json")


if __name__ == "__main__":
    unittest.main()
