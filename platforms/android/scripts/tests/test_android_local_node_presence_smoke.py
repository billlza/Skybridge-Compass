import importlib.util
import pathlib
import unittest


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "run_android_local_node_presence_smoke.py"


def load_smoke_module():
    spec = importlib.util.spec_from_file_location("android_local_node_presence_smoke", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


smoke = load_smoke_module()


class AndroidLocalNodePresenceSmokeTest(unittest.TestCase):
    def test_extract_presence_port_from_android_log(self):
        log = """
07-05 18:00:01.000 I/AndroidLocalNode(1234): Android Bonjour presence active on _skybridge._tcp port=49152
"""
        self.assertEqual(smoke.extract_presence_port(log), 49152)

    def test_extract_presence_port_returns_none_when_log_is_absent(self):
        self.assertIsNone(smoke.extract_presence_port("07-05 18:00:01.000 I/SkyBridgeApp: Monitoring initialized"))

    def test_extract_presence_failure_from_android_log(self):
        log = """
07-05 18:00:01.000 E/AndroidLocalNode(1234): Android Bonjour presence stopped after startup failure
"""
        self.assertIn("startup failure", smoke.extract_presence_failure(log))

    def test_extract_presence_failure_from_fatal_runtime_log(self):
        log = """
07-05 18:00:01.000 E/AndroidRuntime(1234): FATAL EXCEPTION: DefaultDispatcher-worker-4
"""
        self.assertIn("FATAL EXCEPTION", smoke.extract_presence_failure(log))

    def test_extract_presence_failure_returns_none_when_log_is_absent(self):
        self.assertIsNone(smoke.extract_presence_failure("07-05 18:00:01.000 I/SkyBridgeApp: Monitoring initialized"))

    def test_classifies_nsd_timeout_after_framework_add_remove(self):
        app_log = """
07-06 00:19:23.459 E/AndroidLocalNode(6144): com.skybridge.compass.discovery.data.datasources.BonjourAdvertisingException: NSD registration timed out after 10000ms for _skybridge._tcp
"""
        system_log = """
07-06 00:19:13.454 I/serviceDiscovery(676): [MdnsAdvertiser] Adding service name: android, type: _skybridge._tcp, port: 36967
07-06 00:19:23.455 I/serviceDiscovery(676): [MdnsAdvertiser] Removing service with ID 81
"""
        self.assertEqual(
            smoke.classify_presence_failure(app_log, system_log),
            "nsd_registration_callback_timeout_after_framework_add_remove",
        )

    def test_classifies_nsd_timeout_before_framework_add(self):
        app_log = """
07-06 00:19:23.459 E/AndroidLocalNode(6144): com.skybridge.compass.discovery.data.datasources.BonjourAdvertisingException: NSD registration timed out after 10000ms for _skybridge._tcp
"""
        self.assertEqual(
            smoke.classify_presence_failure(app_log, ""),
            "nsd_registration_callback_timeout_before_framework_add",
        )

    def test_classifies_emulator_nat_as_diagnostic_only(self):
        app_log = """
07-06 01:30:10.000 E/AndroidLocalNode(6144): Android emulator NAT is diagnostic-only and does not prove Mac/iOS Bonjour visibility
"""
        self.assertEqual(
            smoke.classify_presence_failure(app_log, ""),
            "android_emulator_nat_not_bonjour_visible",
        )

    def test_classifies_missing_android_local_network_permission(self):
        app_log = """
07-06 01:30:10.000 E/AndroidLocalNode(6144): Bonjour advertising requires android.permission.ACCESS_LOCAL_NETWORK on Android API 37+
"""
        self.assertEqual(
            smoke.classify_presence_failure(app_log, ""),
            "android_local_network_permission_missing",
        )

    def test_parse_browse_instances_keeps_unique_skybridge_instances(self):
        output = """
Browsing for _skybridge._tcp.local
DATE: ---Sun 05 Jul 2026---
18:01:11.111  Add     3  4 local.               _skybridge._tcp.     android-1234
18:01:12.111  Add     3  4 local.               _skybridge._tcp.     macbook-pro
18:01:13.111  Add     3  4 local.               _skybridge._tcp.     android-1234
"""
        self.assertEqual(smoke.parse_browse_instances(output), ["android-1234", "macbook-pro"])

    def test_resolved_instance_requires_android_platform_and_matching_port(self):
        resolved = """
Lookup android-1234._skybridge._tcp.local
android-1234._skybridge._tcp.local. can be reached at android.local.:49152
txtvers=1 platform=android deviceId=abc pubKeyFP=def
"""
        self.assertTrue(smoke.resolved_instance_matches_android_port(resolved, 49152))
        self.assertFalse(smoke.resolved_instance_matches_android_port(resolved, 49153))
        self.assertFalse(
            smoke.resolved_instance_matches_android_port(
                resolved.replace("platform=android", "platform=macos"),
                49152,
            )
        )


if __name__ == "__main__":
    unittest.main()
