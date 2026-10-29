#!/usr/bin/env python3

from __future__ import annotations

import unittest

from devicectl_device_selection import installable_physical_ios_profile_identifiers


def device(
    *,
    udid: str = "physical-udid",
    product: str = "iPad16,3",
    reality: str = "physical",
    tunnel: str = "connected",
    pairing: str = "paired",
    installable: bool = True,
    simulator: bool = False,
) -> dict:
    return {
        "identifier": "coredevice-identifier",
        "hardwareProperties": {
            "udid": udid,
            "productType": product,
            "platform": "iOS",
            "reality": reality,
        },
        "connectionProperties": {
            "tunnelState": tunnel,
            "pairingState": pairing,
        },
        "visibilityClass": "simulators" if simulator else "default",
        "deviceProperties": {
            "provider": (
                "com.apple.CoreSimulator.SimulatorCoreDevicePlugin"
                if simulator
                else "com.apple.CoreDevice"
            )
        },
        "capabilities": (
            [{"featureIdentifier": "com.apple.coredevice.feature.installapp"}]
            if installable
            else []
        ),
    }


class CoreDeviceSelectionTests(unittest.TestCase):
    def selected(self, candidate: dict, prefix: str = "iPad") -> set[str]:
        return installable_physical_ios_profile_identifiers(
            {"result": {"devices": [candidate]}},
            product_prefix=prefix,
        )

    def test_selects_connected_installable_physical_ipad_hardware_udid(self) -> None:
        self.assertEqual(self.selected(device()), {"physical-udid"})

    def test_rejects_offline_or_unpaired_device(self) -> None:
        self.assertEqual(
            self.selected(device(tunnel="disconnected", pairing="paired")),
            set(),
        )
        self.assertEqual(
            self.selected(device(tunnel="connected", pairing="unpaired")),
            set(),
        )

    def test_rejects_simulator_and_nonphysical_reality(self) -> None:
        self.assertEqual(self.selected(device(reality="simulated", simulator=True)), set())

    def test_rejects_device_without_install_capability(self) -> None:
        self.assertEqual(self.selected(device(installable=False)), set())

    def test_filters_requested_family_and_never_substitutes_coredevice_identifier(self) -> None:
        self.assertEqual(self.selected(device(product="iPhone17,1")), set())
        self.assertEqual(self.selected(device(udid="")), set())


if __name__ == "__main__":
    unittest.main()
