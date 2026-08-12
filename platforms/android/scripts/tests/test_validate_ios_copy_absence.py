#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "validate_ios_copy_absence.py"
SPEC = importlib.util.spec_from_file_location("validate_ios_copy_absence", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class IOSCopyAbsenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "result.json"
        self.source = "Library/Application Support/example/history.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, *, code: object = 7000, description: str | None = None) -> None:
        self.path.write_text(
            json.dumps(
                {
                    "error": {
                        "code": code,
                        "domain": "com.apple.dt.CoreDeviceError",
                        "userInfo": {
                            "NSLocalizedDescription": {
                                "string": description
                                or f"Failed to retrieve the file node for {self.source}"
                            }
                        },
                    },
                    "info": {
                        "commandType": "devicectl.device.copy.from",
                        "outcome": "failed",
                    },
                }
            ),
            encoding="utf-8",
        )

    def test_exact_missing_file_result_is_accepted(self) -> None:
        self.write()
        MODULE.validate_absence_result(self.path, self.source)

    def test_transport_or_permission_failures_are_rejected(self) -> None:
        self.write(code=7001)
        with self.assertRaisesRegex(MODULE.IOSCopyAbsenceError, "does not prove"):
            MODULE.validate_absence_result(self.path, self.source)
        self.write(description="Permission denied")
        with self.assertRaisesRegex(MODULE.IOSCopyAbsenceError, "does not prove"):
            MODULE.validate_absence_result(self.path, self.source)

    def test_bool_code_and_duplicate_keys_are_rejected(self) -> None:
        self.write(code=True)
        with self.assertRaisesRegex(MODULE.IOSCopyAbsenceError, "does not prove"):
            MODULE.validate_absence_result(self.path, self.source)
        self.path.write_text(
            '{"error":{},"error":{},"info":{}}',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(MODULE.IOSCopyAbsenceError, "duplicate"):
            MODULE.validate_absence_result(self.path, self.source)

    def test_malformed_or_success_output_is_rejected(self) -> None:
        self.path.write_text("not-json", encoding="utf-8")
        with self.assertRaisesRegex(MODULE.IOSCopyAbsenceError, "unreadable"):
            MODULE.validate_absence_result(self.path, self.source)
        self.path.write_text('{"info":{"outcome":"success"}}', encoding="utf-8")
        with self.assertRaisesRegex(MODULE.IOSCopyAbsenceError, "top-level"):
            MODULE.validate_absence_result(self.path, self.source)


if __name__ == "__main__":
    unittest.main()
