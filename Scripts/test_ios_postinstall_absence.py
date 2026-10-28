#!/usr/bin/env python3
from pathlib import Path
import json
import subprocess
import tempfile
import unittest


class IOSPostinstallAbsenceTests(unittest.TestCase):
    def test_checkpoint_never_replaces_verified_absence(self) -> None:
        cases = (
            ([1], "", True, 1),
            ([0, 1], "CLOSED\n", True, 2),
            ([0, 0], "CLOSED\n", False, 2),
            ([0, 2], "CLOSED\n", False, 2),
            ([2], "CLOSED\n", False, 1),
            ([0], "COMPLETE\n", False, 1),
            ([0], "", False, 1),
        )
        for statuses, answer, succeeds, count in cases:
            with self.subTest(statuses=statuses, answer=answer), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "statuses.json").write_text(json.dumps(statuses))
                helper = root / "presence.py"
                helper.write_text(
                    "import json,sys\nfrom pathlib import Path\n"
                    "p=Path(__file__).with_name('statuses.json')\n"
                    "s=json.loads(p.read_text()); status=s.pop(0)\n"
                    "p.write_text(json.dumps(s)); sys.exit(status)\n"
                )
                # Use a shell-local counter to make each actual snapshot
                # observable while substituting only the device I/O boundary.
                shell = """
set -euo pipefail
source "$1"
capture_journal="$4"
skybridge_ios_process_snapshot() {
  printf 'snapshot\n' >> "$capture_journal"
  printf 'observed\n' > "$2"
}
skybridge_ios_require_postinstall_app_absence "$2" device app "$3" 1
"""
                result = subprocess.run(
                    ["/bin/bash", "-c", shell, "capture-test",
                     str(Path(__file__).with_name("real_device_ios_process_ownership.sh")),
                     str(helper), str(root / "processes.json"), str(root / "journal")],
                    input=answer, capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                self.assertEqual(len((root / "journal").read_text().splitlines()), count)
                if statuses[0] == 0:
                    self.assertTrue((root / "processes-unowned.json").is_file())


if __name__ == "__main__":
    unittest.main()
