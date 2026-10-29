#!/usr/bin/env python3
"""Tests for the universal liboqs simulator header merger."""

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest


SCRIPT_PATH = pathlib.Path(__file__).with_name("merge_liboqs_simulator_headers.py")
SPEC = importlib.util.spec_from_file_location("merge_liboqs_simulator_headers", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT_PATH}")
MERGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MERGER)


COMMON_PREFIX = """#ifndef OQS_CONFIG_H
#define OQS_CONFIG_H
#define OQS_VERSION_TEXT \"0.16.0\"
"""
COMMON_SUFFIX = """/* #undef ARCH_ARM32_V7 */
#define OQS_BUILD_ONLY_LIB 1
#endif
"""


def config(architecture: str) -> str:
    if architecture == "arm64":
        architecture_lines = """#define OQS_COMPILE_BUILD_TARGET \"arm64-Darwin-27.0.0\"
/* #undef OQS_DIST_X86_64_BUILD */
#define OQS_DIST_ARM64_V8_BUILD 1
/* #undef ARCH_X86_64 */
#define ARCH_ARM64v8 1
"""
    else:
        architecture_lines = """#define OQS_COMPILE_BUILD_TARGET \"x86_64-Darwin-27.0.0\"
#define OQS_DIST_X86_64_BUILD 1
/* #undef OQS_DIST_ARM64_V8_BUILD */
#define ARCH_X86_64 1
/* #undef ARCH_ARM64v8 */
"""
    return COMMON_PREFIX + architecture_lines + COMMON_SUFFIX


class LiboqsSimulatorHeaderMergeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.temporary_directory.name)
        self.arm64 = root / "arm64"
        self.x86_64 = root / "x86_64"
        self.output = root / "universal"
        for directory, architecture in ((self.arm64, "arm64"), (self.x86_64, "x86_64")):
            (directory / "oqs").mkdir(parents=True)
            (directory / "oqs/oqs.h").write_text("#include <oqs/oqsconfig.h>\n", encoding="utf-8")
            (directory / "oqs/oqsconfig.h").write_text(
                config(architecture), encoding="utf-8"
            )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_merges_only_architecture_configuration(self) -> None:
        MERGER.merge_headers(self.arm64, self.x86_64, self.output)
        merged = (self.output / "oqs/oqsconfig.h").read_text(encoding="utf-8")
        self.assertIn("#if defined(__arm64__)", merged)
        self.assertIn("#elif defined(__x86_64__)", merged)
        self.assertIn('#error "liboqs simulator headers require arm64 or x86_64"', merged)
        self.assertEqual(
            (self.output / "oqs/oqs.h").read_bytes(),
            (self.arm64 / "oqs/oqs.h").read_bytes(),
        )

    def test_rejects_nonconfiguration_header_drift(self) -> None:
        (self.x86_64 / "oqs/oqs.h").write_text("tampered\n", encoding="utf-8")
        with self.assertRaisesRegex(MERGER.HeaderMergeError, "outside oqsconfig.h"):
            MERGER.merge_headers(self.arm64, self.x86_64, self.output)

    def test_rejects_nonarchitecture_configuration_drift(self) -> None:
        x86_config = self.x86_64 / "oqs/oqsconfig.h"
        x86_config.write_text(
            x86_config.read_text(encoding="utf-8").replace("0.16.0", "0.16.1"),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(MERGER.HeaderMergeError, "outside architecture macros"):
            MERGER.merge_headers(self.arm64, self.x86_64, self.output)

    def test_rejects_existing_output(self) -> None:
        self.output.mkdir()
        with self.assertRaisesRegex(MERGER.HeaderMergeError, "already exists"):
            MERGER.merge_headers(self.arm64, self.x86_64, self.output)


if __name__ == "__main__":
    unittest.main()
