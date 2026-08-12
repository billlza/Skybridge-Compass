#!/usr/bin/env python3
"""Behavior tests for native-PQC gate test-package ownership and cleanup."""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from typing import Any


ANDROID_ROOT = Path(__file__).resolve().parents[2]
RUNNER_SOURCE = ANDROID_ROOT / "scripts/run_android_pqc_native_runtime_gate.sh"
VALIDATOR_SOURCE = ANDROID_ROOT / "scripts/validate_android_pqc_native_runtime_evidence.py"
LIBRARY_SOURCES = (
    ANDROID_ROOT / "scripts/lib/android_env.sh",
    ANDROID_ROOT / "scripts/lib/source_provenance.sh",
    ANDROID_ROOT / "scripts/lib/strict_gradle_output.sh",
)

SAMSUNG_SERIAL = "fixture-samsung-api36"
API37_SERIAL = "fixture-api37-16k"
APP_PACKAGE = "com.skybridge.compass.debug"
TEST_PACKAGE = "com.skybridge.compass.debug.nativepqc.test"


FAKE_GRADLEW = r"""
#!/usr/bin/env python3
from __future__ import annotations

import sys
import zipfile
from pathlib import Path


def write_apk(path: Path, *, app: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("AndroidManifest.xml", b"fixture-manifest")
        if app:
            archive.writestr("lib/arm64-v8a/libskybridge_pqc.so", b"fixture-arm64")
            archive.writestr("lib/x86_64/libskybridge_pqc.so", b"fixture-x86-64")


def main() -> int:
    arguments = sys.argv[1:]
    if arguments == ["--stop"]:
        return 0
    required_tasks = {":app:assembleDebug", ":app:assembleDebugAndroidTest"}
    if not required_tasks.issubset(arguments):
        print("fake gradlew received an unsupported task set", file=sys.stderr)
        return 2
    expected_application_id = (
        "-PskybridgeNativePqcGateTestApplicationId="
        "com.skybridge.compass.debug.nativepqc.test"
    )
    if arguments.count(expected_application_id) != 1:
        print("fake gradlew did not receive the dedicated test application id", file=sys.stderr)
        return 3
    root = Path(__file__).resolve().parent
    write_apk(root / "app/build/outputs/apk/debug/app-debug.apk", app=True)
    write_apk(
        root / "app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk",
        app=False,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
"""


FAKE_ADB = r"""
#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any


APP_PACKAGE = "com.skybridge.compass.debug"
TEST_PACKAGE = "com.skybridge.compass.debug.nativepqc.test"
TEST_COMPONENT = (
    "com.skybridge.compass.debug.nativepqc.test/"
    "com.skybridge.compass.android.HiltTestRunner"
)

STATE_PATH = Path(os.environ["FAKE_ADB_STATE"])
SCENARIO_PATH = Path(os.environ["FAKE_ADB_SCENARIO"])
EVENT_PATH = Path(os.environ["FAKE_ADB_EVENTS"])
APP_APK = Path(os.environ["FAKE_ADB_APP_APK"]).resolve()
TEST_APK = Path(os.environ["FAKE_ADB_TEST_APK"]).resolve()


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object in {path}")
    return value


def save_state(state: dict[str, Any]) -> None:
    temporary = STATE_PATH.with_name(f".{STATE_PATH.name}.pending")
    temporary.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, STATE_PATH)


def record(**fields: object) -> None:
    with EVENT_PATH.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(fields, sort_keys=True) + "\n")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def instrumentation_argument(command: list[str], name: str) -> str:
    for index in range(len(command) - 2):
        if command[index] == "-e" and command[index + 1] == name:
            return command[index + 2]
    raise ValueError(f"missing instrumentation argument {name}")


def installed_package(
    device: dict[str, Any],
    package_name: str,
) -> dict[str, str] | None:
    value = device["packages"].get(package_name)
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("installed package state must be an object")
    return value


def install(
    serial: str,
    command: list[str],
    state: dict[str, Any],
    scenario: dict[str, Any],
) -> int:
    local_path = Path(command[-1]).resolve()
    if local_path == APP_APK:
        package_name = APP_PACKAGE
        package_kind = "app"
    elif local_path == TEST_APK:
        package_name = TEST_PACKAGE
        package_kind = "test"
    else:
        record(serial=serial, operation="install", package="unknown", outcome="rejected")
        print("Failure [UNKNOWN_APK]", file=sys.stderr)
        return 21

    packages = state["devices"][serial]["packages"]
    remote_path = f"/data/app/{serial}-{package_kind}/base.apk"
    local_digest = sha256(local_path)

    if package_kind == "test":
        behavior = scenario.get("test_install", {}).get(serial, "success")
        if behavior == "fail_absent":
            record(
                serial=serial,
                operation="install",
                package=package_kind,
                outcome=behavior,
            )
            print("Failure [FIXTURE_TEST_INSTALL_ABSENT]", file=sys.stderr)
            return 31
        if behavior in {"fail_same", "fail_different"}:
            installed_digest = local_digest if behavior == "fail_same" else "f" * 64
            packages[package_name] = {
                "path": remote_path,
                "sha256": installed_digest,
            }
            save_state(state)
            record(
                serial=serial,
                operation="install",
                package=package_kind,
                outcome=behavior,
            )
            print("Failure [FIXTURE_TEST_INSTALL_AFTER_WRITE]", file=sys.stderr)
            return 32
        if behavior != "success":
            raise ValueError(f"unsupported test-install behavior: {behavior}")

    installed_digest = local_digest
    if package_kind == "app" and serial in scenario.get("different_app_digest", []):
        installed_digest = "e" * 64
    packages[package_name] = {
        "path": remote_path,
        "sha256": installed_digest,
    }
    save_state(state)
    record(
        serial=serial,
        operation="install",
        package=package_kind,
        outcome="success",
    )
    print("Success")
    return 0


def shell_command(
    serial: str,
    command: list[str],
    state: dict[str, Any],
    scenario: dict[str, Any],
) -> int:
    device = state["devices"][serial]
    if command == ["getprop", "ro.build.version.sdk"]:
        print(device["api"])
        return 0
    if command == ["getconf", "PAGE_SIZE"]:
        print(device["page_size"])
        return 0
    if command == ["getprop", "ro.product.cpu.abi"]:
        print(device["abi"])
        return 0
    if command == ["getprop", "ro.product.manufacturer"]:
        print(device["manufacturer"])
        return 0
    if command == ["getprop", "ro.kernel.qemu"]:
        print(device["qemu"])
        return 0

    if command[:2] == ["pm", "path"] and len(command) == 3:
        package_name = command[2]
        package = installed_package(device, package_name)
        record(
            serial=serial,
            operation="query_package",
            package=package_name,
            present=package is not None,
        )
        if package is not None:
            print(f"package:{package['path']}")
            return 0
        return 1

    if command[:1] == ["sha256sum"] and len(command) == 2:
        remote_path = command[1]
        for package in device["packages"].values():
            if package["path"] == remote_path:
                print(f"{package['sha256']}  {remote_path}")
                return 0
        print("sha256sum: fixture path not found", file=sys.stderr)
        return 41

    if command == ["pm", "list", "instrumentation"]:
        if installed_package(device, TEST_PACKAGE) is not None:
            print(f"instrumentation:{TEST_COMPONENT} (target={APP_PACKAGE})")
        return 0

    if command[:2] == ["am", "instrument"]:
        profile = instrumentation_argument(command, "skybridgePqcRuntimeProfile")
        behavior = scenario.get("instrumentation", {}).get(serial, "success")
        if behavior == "fail":
            record(
                serial=serial,
                operation="instrumentation",
                outcome="failed",
            )
            print("INSTRUMENTATION_FAILED: fixture failure", file=sys.stderr)
            return 51
        if behavior != "success":
            raise ValueError(f"unsupported instrumentation behavior: {behavior}")

        record(serial=serial, operation="instrumentation", outcome="success")
        print(
            "INSTRUMENTATION_STATUS: stream="
            "SB-PQC-NATIVE-RUNTIME schema=1 "
            f"profile={profile} provider=liboqs-android "
            f"api={device['api']} abi={device['abi']} "
            f"page_size={device['page_size']} "
            "native_load=true mlkem_keygen=true mlkem_encaps=true "
            "mlkem_decaps=true mlkem_secret_match=true mldsa_keygen=true "
            "mldsa_sign=true mldsa_verify=true mldsa_negative_message=true "
            "mldsa_negative_signature=true cleanup=true"
        )
        print("Time: 0.001")
        print()
        print("OK (1 test)")
        print("INSTRUMENTATION_CODE: -1")
        if serial in scenario.get("mutate_app_after_instrumentation", []):
            with APP_APK.open("ab") as handle:
                handle.write(b"fixture-post-device-mutation")
        return 0

    record(serial=serial, operation="unsupported_shell", command=command)
    print(f"unsupported fake adb shell command: {command}", file=sys.stderr)
    return 61


def main() -> int:
    state = read_json(STATE_PATH)
    scenario = read_json(SCENARIO_PATH)
    arguments = sys.argv[1:]
    if len(arguments) < 3 or arguments[0] != "-s":
        print("fake adb requires an explicit -s serial", file=sys.stderr)
        return 2
    serial = arguments[1]
    command = arguments[2:]
    if serial not in state["devices"]:
        print("unknown fake adb serial", file=sys.stderr)
        return 3

    if command == ["get-state"]:
        print("device")
        return 0
    if command == ["get-serialno"]:
        print(serial)
        return 0
    if command[:1] == ["install"]:
        return install(serial, command, state, scenario)
    if command[:1] == ["uninstall"] and len(command) == 2:
        package_name = command[1]
        package_kind = "test" if package_name == TEST_PACKAGE else "app"
        package = state["devices"][serial]["packages"].pop(package_name, None)
        if package is None:
            record(
                serial=serial,
                operation="uninstall",
                package=package_kind,
                outcome="absent",
            )
            print("Failure [NOT_INSTALLED]", file=sys.stderr)
            return 71
        save_state(state)
        record(
            serial=serial,
            operation="uninstall",
            package=package_kind,
            outcome="success",
        )
        print("Success")
        return 0
    if command[:1] == ["shell"]:
        return shell_command(serial, command[1:], state, scenario)

    record(serial=serial, operation="unsupported", command=command)
    print(f"unsupported fake adb command: {command}", file=sys.stderr)
    return 81


if __name__ == "__main__":
    raise SystemExit(main())
"""


class GateHarness:
    """A disposable Git worktree and deterministic two-device ADB model."""

    def __init__(
        self,
        *,
        scenario: dict[str, object] | None = None,
        preexisting_test_packages: tuple[str, ...] = (),
    ) -> None:
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name)
        self.repo = self.root / "repo"
        self.bin_dir = self.root / "bin"
        self.state_path = self.root / "adb-state.json"
        self.scenario_path = self.root / "adb-scenario.json"
        self.events_path = self.root / "adb-events.jsonl"
        self.evidence_dir = self.root / "evidence"
        self.tmp_dir = self.root / "tmp"
        self.fake_adb = self.bin_dir / "adb"
        self.runner = self.repo / "scripts/run_android_pqc_native_runtime_gate.sh"
        self.app_apk = self.repo / "app/build/outputs/apk/debug/app-debug.apk"
        self.test_apk = (
            self.repo
            / "app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
        )

        self._create_repository()
        self._create_fake_adb()
        self.tmp_dir.mkdir()
        self._write_scenario(scenario or {})
        self._write_initial_state(preexisting_test_packages)
        self.commit = self._git("rev-parse", "HEAD").stdout.strip()
        self.common_git_dir = Path(
            self._git(
                "rev-parse",
                "--path-format=absolute",
                "--git-common-dir",
            ).stdout.strip()
        )
        self.lane_lock = self.common_git_dir / "skybridge-native-pqc-runtime.lock"

    def close(self) -> None:
        self._temporary.cleanup()

    def _git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(self.repo), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )

    @staticmethod
    def _write_executable(path: Path, source: str) -> None:
        path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _create_repository(self) -> None:
        (self.repo / "scripts/lib").mkdir(parents=True)
        shutil.copy2(RUNNER_SOURCE, self.runner)
        shutil.copy2(
            VALIDATOR_SOURCE,
            self.repo / "scripts/validate_android_pqc_native_runtime_evidence.py",
        )
        for source in LIBRARY_SOURCES:
            shutil.copy2(source, self.repo / "scripts/lib" / source.name)
        self._write_executable(self.repo / "gradlew", FAKE_GRADLEW)
        (self.repo / "local.properties").write_text(
            "sdk.dir=/fixture/android-sdk\n",
            encoding="utf-8",
        )
        (self.repo / ".gitignore").write_text("app/build/\n", encoding="utf-8")
        self._git("init", "-q")
        self._git("add", ".")
        subprocess.run(
            [
                "git",
                "-C",
                str(self.repo),
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "-q",
                "-m",
                "fixture",
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    def _create_fake_adb(self) -> None:
        self.bin_dir.mkdir()
        self._write_executable(self.fake_adb, FAKE_ADB)

    def _write_scenario(self, scenario: dict[str, object]) -> None:
        self.scenario_path.write_text(
            json.dumps(scenario, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def _write_initial_state(self, preexisting_test_packages: tuple[str, ...]) -> None:
        devices: dict[str, dict[str, object]] = {
            SAMSUNG_SERIAL: {
                "abi": "arm64-v8a",
                "api": 36,
                "manufacturer": "Samsung",
                "packages": {},
                "page_size": 4096,
                "qemu": "",
            },
            API37_SERIAL: {
                "abi": "x86_64",
                "api": 37,
                "manufacturer": "Fixture",
                "packages": {},
                "page_size": 16384,
                "qemu": "1",
            },
        }
        for serial in preexisting_test_packages:
            packages = devices[serial]["packages"]
            if not isinstance(packages, dict):
                raise TypeError("fixture package state must be a dictionary")
            packages[TEST_PACKAGE] = {
                "path": f"/data/app/{serial}-preexisting-test/base.apk",
                "sha256": "a" * 64,
            }
        self.state_path.write_text(
            json.dumps({"devices": devices}, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def run(self) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "FAKE_ADB_APP_APK": str(self.app_apk),
                "FAKE_ADB_EVENTS": str(self.events_path),
                "FAKE_ADB_SCENARIO": str(self.scenario_path),
                "FAKE_ADB_STATE": str(self.state_path),
                "FAKE_ADB_TEST_APK": str(self.test_apk),
                "TMPDIR": str(self.tmp_dir),
            }
        )
        result = subprocess.run(
            [
                str(self.runner),
                "--samsung-api36-4k-serial",
                SAMSUNG_SERIAL,
                "--api37-16k-serial",
                API37_SERIAL,
                "--api37-16k-abi",
                "x86_64",
                "--expected-source-commit",
                self.commit,
                "--evidence-dir",
                str(self.evidence_dir),
                "--adb",
                str(self.fake_adb),
            ],
            cwd=self.repo,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if self.lane_lock.exists():
            raise AssertionError(f"native-PQC lane lock was not released: {self.lane_lock}")
        return result

    def events(self) -> list[dict[str, Any]]:
        if not self.events_path.exists():
            return []
        events: list[dict[str, Any]] = []
        for line in self.events_path.read_text(encoding="utf-8").splitlines():
            value = json.loads(line)
            if not isinstance(value, dict):
                raise TypeError("fake ADB event must be a JSON object")
            events.append(value)
        return events

    def matching_events(self, operation: str, **fields: object) -> list[dict[str, Any]]:
        return [
            event
            for event in self.events()
            if event.get("operation") == operation
            and all(event.get(key) == value for key, value in fields.items())
        ]

    def state(self) -> dict[str, Any]:
        value = json.loads(self.state_path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise TypeError("fake ADB state must be a JSON object")
        return value

    def installed_test_package(self, serial: str) -> dict[str, str] | None:
        package = self.state()["devices"][serial]["packages"].get(TEST_PACKAGE)
        if package is None:
            return None
        if not isinstance(package, dict):
            raise TypeError("installed test package must be a JSON object")
        return package


class NativePqcRuntimeGateBehaviorTests(unittest.TestCase):
    def harness(self, **arguments: object) -> GateHarness:
        harness = GateHarness(**arguments)
        self.addCleanup(harness.close)
        return harness

    def assert_test_uninstalls(
        self,
        harness: GateHarness,
        *,
        samsung: int,
        api37: int,
    ) -> None:
        self.assertEqual(
            len(
                harness.matching_events(
                    "uninstall",
                    serial=SAMSUNG_SERIAL,
                    package="test",
                )
            ),
            samsung,
        )
        self.assertEqual(
            len(
                harness.matching_events(
                    "uninstall",
                    serial=API37_SERIAL,
                    package="test",
                )
            ),
            api37,
        )

    def test_preexisting_test_package_fails_without_install_or_uninstall(self) -> None:
        harness = self.harness(preexisting_test_packages=(SAMSUNG_SERIAL,))

        result = harness.run()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("test package existed before this run", result.stderr)
        self.assertEqual(harness.matching_events("install"), [])
        self.assertEqual(harness.matching_events("uninstall"), [])
        self.assertIsNotNone(harness.installed_test_package(SAMSUNG_SERIAL))

    def test_success_installs_one_pair_and_removes_one_test_package_per_device(self) -> None:
        harness = self.harness()

        result = harness.run()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for serial in (SAMSUNG_SERIAL, API37_SERIAL):
            self.assertEqual(
                len(harness.matching_events("install", serial=serial, package="app")),
                1,
            )
            self.assertEqual(
                len(harness.matching_events("install", serial=serial, package="test")),
                1,
            )
            self.assertIsNone(harness.installed_test_package(serial))
        self.assert_test_uninstalls(harness, samsung=1, api37=1)
        evidence = json.loads(
            (harness.evidence_dir / "native-pqc-runtime-evidence.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(evidence["sourceCommit"], harness.commit)
        self.assertIs(evidence["matrixComplete"], True)

    def test_failed_second_test_install_without_package_does_not_uninstall_it(self) -> None:
        harness = self.harness(
            scenario={"test_install": {API37_SERIAL: "fail_absent"}}
        )

        result = harness.run()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_test_uninstalls(harness, samsung=1, api37=0)
        self.assertIsNone(harness.installed_test_package(API37_SERIAL))
        self.assertEqual(
            len(harness.matching_events("install", serial=API37_SERIAL, package="test")),
            1,
        )

    def test_nonzero_test_install_with_same_digest_removes_only_run_owned_package(self) -> None:
        harness = self.harness(
            scenario={"test_install": {API37_SERIAL: "fail_same"}}
        )

        result = harness.run()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_test_uninstalls(harness, samsung=1, api37=1)
        self.assertIsNone(harness.installed_test_package(API37_SERIAL))

    def test_nonzero_test_install_with_different_digest_refuses_uninstall(self) -> None:
        harness = self.harness(
            scenario={"test_install": {API37_SERIAL: "fail_different"}}
        )

        result = harness.run()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("not owned by this run", result.stderr)
        self.assertIn("refusing uninstall", result.stderr)
        self.assert_test_uninstalls(harness, samsung=1, api37=0)
        package = harness.installed_test_package(API37_SERIAL)
        self.assertIsNotNone(package)
        self.assertEqual(package["sha256"], "f" * 64)

    def test_second_instrumentation_failure_cleans_only_current_owned_package(self) -> None:
        harness = self.harness(
            scenario={"instrumentation": {API37_SERIAL: "fail"}}
        )

        result = harness.run()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_test_uninstalls(harness, samsung=1, api37=1)
        self.assertIsNone(harness.installed_test_package(SAMSUNG_SERIAL))
        self.assertIsNone(harness.installed_test_package(API37_SERIAL))

    def test_post_install_app_digest_failure_does_not_reclean_first_device(self) -> None:
        harness = self.harness(scenario={"different_app_digest": [API37_SERIAL]})

        result = harness.run()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("installed APK bytes do not match", result.stderr)
        self.assert_test_uninstalls(harness, samsung=1, api37=1)
        self.assertIsNone(harness.installed_test_package(SAMSUNG_SERIAL))
        self.assertIsNone(harness.installed_test_package(API37_SERIAL))

    def test_post_device_apk_mutation_fails_freeze_without_double_cleanup(self) -> None:
        harness = self.harness(
            scenario={"mutate_app_after_instrumentation": [API37_SERIAL]}
        )

        result = harness.run()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("canonical app APK changed after the fixed build", result.stderr)
        self.assert_test_uninstalls(harness, samsung=1, api37=1)
        self.assertFalse(harness.evidence_dir.exists())


if __name__ == "__main__":
    unittest.main()
