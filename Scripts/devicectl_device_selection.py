#!/usr/bin/env python3
"""Typed CoreDevice selection helpers shared by release evidence producers."""

from __future__ import annotations


INSTALL_APPLICATION_CAPABILITY = "com.apple.coredevice.feature.installapp"
SIMULATOR_PROVIDER = "com.apple.CoreSimulator.SimulatorCoreDevicePlugin"


def _mapping(value: object) -> dict:
    return value if isinstance(value, dict) else {}


def _string(value: object) -> str:
    return value.strip() if isinstance(value, str) else ""


def _nested(value: object, *keys: str) -> object:
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def _device_type(device: dict) -> str:
    hardware = _mapping(device.get("hardwareProperties"))
    evidence = (
        hardware.get("deviceType"),
        hardware.get("productType"),
        hardware.get("marketingName"),
    )
    return " ".join(
        text
        for value in evidence
        if (text := _string(value).lower())
    )


def is_connected_physical_ios_device(device: object) -> bool:
    if not isinstance(device, dict):
        return False
    connection = _mapping(device.get("connectionProperties"))
    tunnel_state = _string(connection.get("tunnelState")).lower()
    pairing_state = _string(connection.get("pairingState")).lower()
    if tunnel_state != "connected" or pairing_state != "paired":
        return False

    hardware_reality = _string(
        _nested(device, "hardwareProperties", "reality")
    ).lower()
    properties_reality = _string(
        _nested(device, "properties", "hardware", "reality")
    ).lower()
    visibility = _string(device.get("visibilityClass")).lower()
    provider = _string(_nested(device, "deviceProperties", "provider"))
    if (
        "physical" not in {hardware_reality, properties_reality}
        or visibility == "simulators"
        or provider == SIMULATOR_PROVIDER
    ):
        return False

    device_type = _device_type(device)
    platform = _string(_nested(device, "hardwareProperties", "platform"))
    if platform != "iOS" and not device_type.startswith(("ipad", "iphone")):
        return False

    capabilities = device.get("capabilities")
    if not isinstance(capabilities, list) or not any(
        isinstance(capability, dict)
        and capability.get("featureIdentifier") == INSTALL_APPLICATION_CAPABILITY
        for capability in capabilities
    ):
        return False
    return True


def installable_physical_ios_profile_identifiers(
    payload: object, *, product_prefix: str
) -> set[str]:
    result = _mapping(_mapping(payload).get("result"))
    devices = result.get("devices")
    if not isinstance(devices, list):
        return set()
    requested = product_prefix.strip().lower()
    identifiers: set[str] = set()
    for device in devices:
        if not is_connected_physical_ios_device(device):
            continue
        assert isinstance(device, dict)
        if requested and not _device_type(device).startswith(requested):
            continue
        # Provisioning profiles contain hardware UDIDs, not CoreDevice's
        # transient `identifier`; bind only to explicit device UDID fields.
        udid = _string(_nested(device, "hardwareProperties", "udid")) or _string(
            _nested(device, "deviceProperties", "udid")
        )
        if udid:
            identifiers.add(udid)
    return identifiers
