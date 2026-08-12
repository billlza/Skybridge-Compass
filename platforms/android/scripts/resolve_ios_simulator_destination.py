#!/usr/bin/env python3
"""Resolve a deterministic xcodebuild destination from simctl device JSON."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from typing import Any


IOS_RUNTIME_PATTERN = re.compile(r"(?:^|\.)iOS-(\d+)(?:-(\d+))?(?:-(\d+))?$")


class SimulatorResolutionError(ValueError):
    """Raised when simctl output contains no usable iOS simulator."""


@dataclass(frozen=True)
class SimulatorCandidate:
    udid: str
    name: str
    state: str
    runtime_identifier: str
    runtime_version: tuple[int, int, int]
    last_booted_at: str

    @property
    def is_booted(self) -> bool:
        return self.state == "Booted"


def _runtime_version(runtime_identifier: str) -> tuple[int, int, int] | None:
    match = IOS_RUNTIME_PATTERN.search(runtime_identifier)
    if match is None:
        return None
    return tuple(int(part or 0) for part in match.groups())


def _candidates(simctl_payload: dict[str, Any]) -> list[SimulatorCandidate]:
    runtimes = simctl_payload.get("devices")
    if not isinstance(runtimes, dict):
        raise SimulatorResolutionError("simctl JSON is missing the devices map")

    candidates: list[SimulatorCandidate] = []
    for runtime_identifier, devices in runtimes.items():
        if not isinstance(runtime_identifier, str) or not isinstance(devices, list):
            continue
        version = _runtime_version(runtime_identifier)
        if version is None:
            continue
        for device in devices:
            if not isinstance(device, dict) or device.get("isAvailable") is not True:
                continue
            udid = device.get("udid")
            name = device.get("name")
            state = device.get("state")
            if not all(isinstance(value, str) and value for value in (udid, name, state)):
                continue
            last_booted_at = device.get("lastBootedAt")
            if not isinstance(last_booted_at, str):
                last_booted_at = device.get("lastUsedAt")
            candidates.append(
                SimulatorCandidate(
                    udid=udid,
                    name=name,
                    state=state,
                    runtime_identifier=runtime_identifier,
                    runtime_version=version,
                    last_booted_at=last_booted_at if isinstance(last_booted_at, str) else "",
                )
            )
    return candidates


def _select_preferred(candidates: list[SimulatorCandidate]) -> SimulatorCandidate:
    if not candidates:
        raise SimulatorResolutionError("no available iOS simulators were reported by simctl")

    booted = [candidate for candidate in candidates if candidate.is_booted]
    selection_pool = booted or candidates
    return max(
        selection_pool,
        key=lambda candidate: (
            candidate.runtime_version,
            candidate.last_booted_at,
            candidate.name,
            candidate.udid,
        ),
    )


def _select_latest_runtime(candidates: list[SimulatorCandidate]) -> SimulatorCandidate:
    if not candidates:
        raise SimulatorResolutionError("no available iOS simulators were reported by simctl")
    return max(
        candidates,
        key=lambda candidate: (
            candidate.runtime_version,
            candidate.last_booted_at,
            candidate.name,
            candidate.udid,
        ),
    )


def select_ios_simulator(simctl_payload: dict[str, Any]) -> SimulatorCandidate:
    return _select_preferred(_candidates(simctl_payload))


def _destination_fields(destination: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for component in destination.split(","):
        key, separator, value = component.partition("=")
        if not separator:
            raise SimulatorResolutionError(
                f"invalid xcodebuild destination component: {component!r}"
            )
        normalized_key = key.strip()
        normalized_value = value.strip()
        if not normalized_key or not normalized_value:
            raise SimulatorResolutionError(
                f"invalid xcodebuild destination component: {component!r}"
            )
        if normalized_key in fields:
            raise SimulatorResolutionError(
                f"duplicate xcodebuild destination field: {normalized_key}"
            )
        fields[normalized_key] = normalized_value
    return fields


def simulator_from_destination(
    simctl_payload: dict[str, Any],
    destination: str,
) -> SimulatorCandidate:
    fields = _destination_fields(destination)
    unsupported_fields = set(fields) - {"platform", "id", "name", "OS"}
    if unsupported_fields:
        raise SimulatorResolutionError(
            "unsupported xcodebuild destination fields: " + ", ".join(sorted(unsupported_fields))
        )
    platform = fields.get("platform")
    if platform is not None and platform != "iOS Simulator":
        raise SimulatorResolutionError(
            f"destination must target an iOS Simulator, got platform={platform!r}"
        )

    candidates = _candidates(simctl_payload)
    target_udid = fields.get("id")
    if target_udid is not None:
        matching_ids = [candidate for candidate in candidates if candidate.udid == target_udid]
        if not matching_ids:
            raise SimulatorResolutionError(
                f"destination simulator id is not available: {target_udid}"
            )
        selected = matching_ids[0]
        target_name = fields.get("name")
        if target_name is not None and selected.name != target_name:
            raise SimulatorResolutionError(
                f"destination name does not match simulator id {target_udid}: {target_name}"
            )
        target_os = fields.get("OS")
        if target_os is not None and target_os.lower() != "latest":
            version_parts = target_os.split(".")
            if not 1 <= len(version_parts) <= 3 or not all(part.isdigit() for part in version_parts):
                raise SimulatorResolutionError(f"invalid destination OS version: {target_os!r}")
            requested_version = tuple(int(part) for part in version_parts)
            if selected.runtime_version[: len(requested_version)] != requested_version:
                raise SimulatorResolutionError(
                    f"destination OS does not match simulator id {target_udid}: {target_os}"
                )
        return selected

    target_name = fields.get("name")
    if target_name is None:
        raise SimulatorResolutionError("destination must include either id or name")
    matching_names = [candidate for candidate in candidates if candidate.name == target_name]

    target_os = fields.get("OS")
    if target_os is not None and target_os.lower() != "latest":
        version_parts = target_os.split(".")
        if not 1 <= len(version_parts) <= 3 or not all(part.isdigit() for part in version_parts):
            raise SimulatorResolutionError(f"invalid destination OS version: {target_os!r}")
        requested_version = tuple(int(part) for part in version_parts)
        matching_names = [
            candidate
            for candidate in matching_names
            if candidate.runtime_version[: len(requested_version)] == requested_version
        ]

    if not matching_names:
        requested = f"name={target_name}"
        if target_os is not None:
            requested += f",OS={target_os}"
        raise SimulatorResolutionError(f"destination simulator is not available: {requested}")
    if target_os is not None and target_os.lower() == "latest":
        return _select_latest_runtime(matching_names)
    return _select_preferred(matching_names)


def xcodebuild_destination(candidate: SimulatorCandidate) -> str:
    return f"platform=iOS Simulator,id={candidate.udid}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--udid-from-destination",
        metavar="DESTINATION",
        help="resolve an explicit xcodebuild simulator destination to an available UDID",
    )
    arguments = parser.parse_args()
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise SimulatorResolutionError("simctl JSON root must be an object")
        if arguments.udid_from_destination is not None:
            print(simulator_from_destination(payload, arguments.udid_from_destination).udid)
        else:
            print(xcodebuild_destination(select_ios_simulator(payload)))
    except (json.JSONDecodeError, SimulatorResolutionError) as error:
        print(f"Unable to resolve an iOS simulator destination: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
