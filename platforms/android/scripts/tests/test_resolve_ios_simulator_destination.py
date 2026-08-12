#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "resolve_ios_simulator_destination.py"
SPEC = importlib.util.spec_from_file_location("resolve_ios_simulator_destination", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def device(
    udid: str,
    *,
    name: str | None = None,
    state: str = "Shutdown",
    available: bool = True,
    last_booted_at: str = "",
    last_used_at: str = "",
) -> dict[str, object]:
    value: dict[str, object] = {
        "udid": udid,
        "name": name or f"Simulator {udid}",
        "state": state,
        "isAvailable": available,
    }
    if last_booted_at:
        value["lastBootedAt"] = last_booted_at
    if last_used_at:
        value["lastUsedAt"] = last_used_at
    return value


class ResolveIosSimulatorDestinationTest(unittest.TestCase):
    def test_prefers_booted_simulator_over_newer_shutdown_runtime(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    device("BOOTED", state="Booted")
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [device("NEWER")],
            }
        }

        selected = MODULE.select_ios_simulator(payload)

        self.assertEqual(selected.udid, "BOOTED")

    def test_prefers_latest_runtime_when_multiple_simulators_are_booted(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    device("OLDER", state="Booted")
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    device("LATEST", state="Booted")
                ],
            }
        }

        selected = MODULE.select_ios_simulator(payload)

        self.assertEqual(selected.udid, "LATEST")

    def test_uses_latest_available_runtime_when_none_are_booted(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [device("OLDER")],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [device("LATEST")],
            }
        }

        selected = MODULE.select_ios_simulator(payload)

        self.assertEqual(selected.udid, "LATEST")

    def test_ignores_non_ios_and_unavailable_devices(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [
                    device("TV", state="Booted")
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    device("UNAVAILABLE", state="Booted", available=False),
                    device("IOS"),
                ],
            }
        }

        selected = MODULE.select_ios_simulator(payload)

        self.assertEqual(selected.udid, "IOS")
        self.assertEqual(
            MODULE.xcodebuild_destination(selected),
            "platform=iOS Simulator,id=IOS",
        )

    def test_rejects_payload_without_available_ios_simulator(self) -> None:
        with self.assertRaisesRegex(
            MODULE.SimulatorResolutionError,
            "no available iOS simulators",
        ):
            MODULE.select_ios_simulator({"devices": {}})

    def test_resolves_explicit_id_only_when_it_is_available(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [device("AVAILABLE")],
            }
        }

        selected = MODULE.simulator_from_destination(
            payload,
            "platform=iOS Simulator,id=AVAILABLE",
        )

        self.assertEqual(selected.udid, "AVAILABLE")
        with self.assertRaisesRegex(
            MODULE.SimulatorResolutionError,
            "simulator id is not available",
        ):
            MODULE.simulator_from_destination(
                payload,
                "platform=iOS Simulator,id=MISSING",
            )

    def test_resolves_exact_name_and_os_without_silent_version_fallback(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    device("MATCH", name="Interop iPhone")
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    device("NEWER", name="Interop iPhone")
                ],
            }
        }

        selected = MODULE.simulator_from_destination(
            payload,
            "platform=iOS Simulator,name=Interop iPhone,OS=26.5",
        )

        self.assertEqual(selected.udid, "MATCH")
        with self.assertRaisesRegex(
            MODULE.SimulatorResolutionError,
            "destination simulator is not available",
        ):
            MODULE.simulator_from_destination(
                payload,
                "platform=iOS Simulator,name=Interop iPhone,OS=26.2",
            )

    def test_rejects_physical_device_destination(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [device("SIM")],
            }
        }

        with self.assertRaisesRegex(
            MODULE.SimulatorResolutionError,
            "must target an iOS Simulator",
        ):
            MODULE.simulator_from_destination(
                payload,
                "platform=iOS,id=PHYSICAL",
            )

    def test_uses_xcode_last_used_at_for_same_runtime_tie_breaking(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    device("RECENT", last_used_at="2026-08-04T07:44:58Z"),
                    device("OLD", last_used_at="2026-08-03T10:25:54Z"),
                ],
            }
        }

        selected = MODULE.select_ios_simulator(payload)

        self.assertEqual(selected.udid, "RECENT")

    def test_latest_destination_prefers_newest_runtime_even_when_older_is_booted(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    device("BOOTED", name="Interop iPhone", state="Booted")
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    device("LATEST", name="Interop iPhone")
                ],
            }
        }

        selected = MODULE.simulator_from_destination(
            payload,
            "platform=iOS Simulator,name=Interop iPhone,OS=latest",
        )

        self.assertEqual(selected.udid, "LATEST")

    def test_id_destination_must_match_name_and_os_constraints(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    device("SIM", name="Interop iPhone")
                ],
            }
        }

        with self.assertRaisesRegex(MODULE.SimulatorResolutionError, "destination name does not match"):
            MODULE.simulator_from_destination(
                payload,
                "platform=iOS Simulator,id=SIM,name=Other iPhone",
            )
        with self.assertRaisesRegex(MODULE.SimulatorResolutionError, "unsupported.*arch"):
            MODULE.simulator_from_destination(
                payload,
                "platform=iOS Simulator,id=SIM,arch=arm64",
            )


if __name__ == "__main__":
    unittest.main()
