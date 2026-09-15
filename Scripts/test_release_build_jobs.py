#!/usr/bin/env python3
"""Execute the release producers' real SwiftPM argument blocks without building."""

from __future__ import annotations

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
PRODUCERS = (
    ("build_dmg.sh", "SWIFTPM_BUILD_ARGS=(", "SkyBridgeCompassApp"),
    ("package_app.sh", "SWIFTPM_BUILD_ARGS=(", "SkyBridgeCompassApp"),
    ("package_app.sh", "local swiftpm_build_args=(", "PowerMetricsHelper"),
)


def producer_block(script: str, start_marker: str) -> tuple[str, str]:
    source = (SCRIPTS / script).read_text(encoding="utf-8")
    validation = next(
        line
        for line in source.splitlines()
        if line.startswith('CONFIGURED_BUILD_JOBS="$(skybridge_configured_build_jobs)"')
    )
    lines = source[source.index(start_marker) :].splitlines()
    invocation = next(
        index for index, line in enumerate(lines) if line.strip() == "swift build \\"
    )
    end = invocation
    while lines[end].rstrip().endswith("\\"):
        end += 1
    return validation, "\n".join(lines[: end + 1])


class ReleaseBuildJobsTests(unittest.TestCase):
    def exercise(
        self, script: str, marker: str, jobs: str | None
    ) -> tuple[subprocess.CompletedProcess[str], list[str] | None]:
        validation, block = producer_block(script, marker)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "swift"
            arguments = root / "arguments.txt"
            executable.write_text(
                '#!/bin/bash\nprintf "%s\\n" "$@" > "$CAPTURED_SWIFT_ARGUMENTS"\n',
                encoding="utf-8",
            )
            executable.chmod(0o700)
            environment = dict(os.environ)
            environment.pop("SKYBRIDGE_BUILD_JOBS", None)
            if jobs is not None:
                environment["SKYBRIDGE_BUILD_JOBS"] = jobs
            environment["PATH"] = str(root) + os.pathsep + environment["PATH"]
            environment["CAPTURED_SWIFT_ARGUMENTS"] = str(arguments)
            program = "\n".join(
                (
                    "set -euo pipefail",
                    "source " + shlex.quote(str(SCRIPTS / "xcodebuild_helpers.sh")),
                    validation,
                    "BUILD_ARCH=arm64",
                    "XCODE_PACKAGE_SCHEME=SkyBridgeCompassApp",
                    "HELPER_EXECUTABLE=PowerMetricsHelper",
                    "SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH='/private/release scratch'",
                    "is_release_distribution_context() { return 0; }",
                    "exercise_producer() {",
                    block,
                    "}",
                    "exercise_producer",
                )
            )
            result = subprocess.run(
                [
                    "/bin/zsh" if script == "package_app.sh" else "/bin/bash",
                    "-c",
                    program,
                ],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            captured = (
                arguments.read_text().splitlines() if arguments.exists() else None
            )
            return result, captured

    def test_valid_limits_reach_every_actual_swiftpm_producer(self) -> None:
        for script, marker, product in PRODUCERS:
            for jobs in ("1", "2", "64"):
                with self.subTest(script=script, product=product, jobs=jobs):
                    result, arguments = self.exercise(script, marker, jobs)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIsNotNone(arguments)
                    assert arguments is not None
                    self.assertEqual(arguments.count("--jobs"), 1)
                    self.assertEqual(arguments[arguments.index("--jobs") + 1], jobs)
                    self.assertEqual(
                        arguments[arguments.index("--product") + 1], product
                    )
                    self.assertEqual(arguments[arguments.index("--arch") + 1], "arm64")
                    self.assertEqual(
                        arguments[arguments.index("--scratch-path") + 1],
                        "/private/release scratch",
                    )
                    self.assertIn("-warnings-as-errors", arguments)

    def test_unset_limit_preserves_defaults(self) -> None:
        for script, marker, _ in PRODUCERS:
            with self.subTest(script=script, marker=marker):
                result, arguments = self.exercise(script, marker, None)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNotNone(arguments)
                assert arguments is not None
                self.assertNotIn("--jobs", arguments)

    def test_invalid_limit_fails_before_swift_is_invoked(self) -> None:
        for script, marker, _ in PRODUCERS:
            for jobs in (
                "",
                "0",
                "-1",
                "01",
                "65",
                "999999999999",
                "1.5",
                "2 3",
                "+2",
                "2;exit",
            ):
                with self.subTest(script=script, marker=marker, jobs=jobs):
                    result, arguments = self.exercise(script, marker, jobs)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("SKYBRIDGE_BUILD_JOBS", result.stderr)
                    self.assertIsNone(arguments)


if __name__ == "__main__":
    unittest.main()
