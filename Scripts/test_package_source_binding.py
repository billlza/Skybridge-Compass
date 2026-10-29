"""Exercise real package source stamps and refusal after actual fixture changes."""
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
SCRIPT = (SCRIPTS / "package_app.sh").read_text()
FUNCTIONS = ("packaging_source_input_snapshot", "validate_packaging_source_input_snapshot",
             "assert_packaging_source_inputs_unchanged", "stamp_packaging_source_inputs")


def definitions():
    result = []
    for name in FUNCTIONS:
        start = SCRIPT.index(f"function {name}() {{")
        result.append(SCRIPT[start:SCRIPT.index("\nfunction ", start + 1)])
    return "\n".join(result)


class PackageSourceBindingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="skybridge-source-binding-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ("Config", "Sources", "Scripts", "Packages", "SkyBridge Compass iOS",
                     "SkyBridgeWidgets.xcodeproj", "XcodeSupport", "VendorProvenance"):
            (self.root / name).mkdir()
        for name in ("Package.swift", "Package.resolved", "project.yml", "Sources/input.swift"):
            (self.root / name).write_text("original\n")
        shutil.copyfile(SCRIPTS / "source_input_digest.py", self.root / "Scripts/source_input_digest.py")
        self.info = self.root / "Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.skybridge.binding-test"}))

    def run_shell(self, body):
        return subprocess.run(["zsh", "-eu", "-c", definitions() +
            '\nROOT_DIR="$1"\nPACKAGING_SOURCE_SNAPSHOT_BEFORE="$(packaging_source_input_snapshot)"\n' + body,
            "source-binding-test", str(self.root), str(self.info)], capture_output=True, text=True)

    def test_unchanged_explicit_sources_are_stamped_without_replacing_other_metadata(self):
        result = self.run_shell('stamp_packaging_source_inputs "$2"\nprint -r -- "$PACKAGING_SOURCE_SNAPSHOT_BEFORE"')
        self.assertEqual(result.returncode, 0, result.stderr)
        expected_digest, expected_count = result.stdout.strip().split()
        metadata = plistlib.loads(self.info.read_bytes())
        self.assertEqual(metadata["CFBundleIdentifier"], "com.skybridge.binding-test")
        self.assertEqual(metadata["SkyBridgePackagingSourceInputDigest"], expected_digest)
        self.assertEqual(metadata["SkyBridgePackagingSourceInputCount"], int(expected_count))
        self.assertIn("SkyBridgeWidgets.xcodeproj", metadata["SkyBridgePackagingSourceInputPaths"])

    def test_changed_source_refuses_before_stamp(self):
        result = self.run_shell('print -r -- changed > "$ROOT_DIR/Sources/input.swift"\nstamp_packaging_source_inputs "$2"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("源码在构建或打包期间发生变化", result.stderr)
        self.assertNotIn("SkyBridgePackagingSourceInputDigest", plistlib.loads(self.info.read_bytes()))

    def test_change_after_stamp_still_refuses_completion(self):
        result = self.run_shell('stamp_packaging_source_inputs "$2"\nprint -r -- changed > "$ROOT_DIR/Sources/input.swift"\nassert_packaging_source_inputs_unchanged')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("源码在构建或打包期间发生变化", result.stderr)

    def test_missing_required_source_is_not_an_empty_digest(self):
        result = self.run_shell('mv "$ROOT_DIR/Sources" "$ROOT_DIR/relocated-sources"\nstamp_packaging_source_inputs "$2"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required source input is missing", result.stderr)
        self.assertNotIn("SkyBridgePackagingSourceInputDigest", plistlib.loads(self.info.read_bytes()))


if __name__ == "__main__":
    unittest.main()
