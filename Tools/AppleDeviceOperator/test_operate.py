import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("apple_operator", Path(__file__).with_name("operate.py"))
operator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operator)


class OperatorContractTests(unittest.TestCase):
    def test_disconnected_inventory_does_not_block_a_successful_live_probe(self):
        device = {"device_id": "device", "udid": "udid", "connection": "disconnected"}
        with patch.object(operator, "physical_devices", return_value=[device]), patch.object(
            operator, "devicectl", return_value={"deviceIdentifier": "device", "passcodeRequired": False}
        ) as probe:
            self.assertEqual(operator.resolve_device("device"), device)
            probe.assert_called_once_with(["device", "info", "lockState", "--device", "device"])

    def test_live_probe_failure_never_becomes_a_cached_success(self):
        device = {"device_id": "device", "udid": "udid", "connection": "connected"}
        with patch.object(operator, "physical_devices", return_value=[device]), patch.object(
            operator, "devicectl", side_effect=operator.OperatorError("device unreachable")
        ), self.assertRaisesRegex(operator.OperatorError, "unreachable"):
            operator.resolve_device("device")

    def test_actions_require_unambiguous_explicit_targets(self):
        for action in [
            {"action": "tap"},
            {"action": "tap", "identifier": "file", "label": "File"},
            {"action": "tap", "identifier": ""},
            {"action": "shell", "text": "ignored"},
            {"action": "snapshot", "identifier": "ignored"},
            {"action": "snapshot_tree", "identifier": "ignored"},
            {"action": "tap", "identifier": "file", "text": "ignored"},
        ]:
            with self.subTest(action=action), self.assertRaises(operator.OperatorError):
                operator.validate_request({"bundle_id": "com.skybridge.compass.ios", "actions": [action]})

    def test_snapshot_and_targeted_text_have_explicit_contracts(self):
        request = {"bundle_id": "com.skybridge.compass.ios", "actions": [
            {"action": "snapshot"}, {"action": "type", "identifier": "field", "text": "hello"},
            {"action": "assert_exists", "identifier": "result"},
        ]}
        self.assertEqual(operator.validate_request(request), request)

    def test_element_type_narrows_an_explicit_selector(self):
        request = {"bundle_id": "com.skybridge.compass.ios", "actions": [
            {"action": "tap", "label": "发送文件", "element_type": "button"},
            {"action": "tap", "identifier": "REDUCE_TRANSPARENCY", "element_type": "switch"},
            {"action": "type", "identifier": "field", "element_type": "text_field", "text": "hello"},
        ]}
        self.assertEqual(operator.validate_request(request), request)

    def test_tree_snapshot_is_an_explicit_read_only_action(self):
        request = {"bundle_id": "com.skybridge.compass.ios", "actions": [{"action": "snapshot_tree"}]}
        self.assertEqual(operator.validate_request(request), request)

    def test_slider_positions_require_finite_bounded_explicit_slider(self):
        for position in [None, True, "0.5", -0.01, 1.01, float("inf"), float("nan")]:
            action = {"action": "adjust_slider", "identifier": "size", "element_type": "slider", "normalized_position": position}
            with self.subTest(position=position), self.assertRaises(operator.OperatorError):
                operator.validate_request({"bundle_id": "com.apple.Preferences", "actions": [action]})
        for position in [0, 0.5, 1]:
            request = {"bundle_id": "com.apple.Preferences", "actions": [
                {"action": "adjust_slider", "identifier": "size", "element_type": "slider", "normalized_position": position}]}
            self.assertEqual(operator.validate_request(request), request)
        request = {"bundle_id": "com.apple.Preferences", "actions": [
            {"action": "adjust_slider", "label": "", "element_type": "slider", "normalized_position": 0.5}]}
        self.assertEqual(operator.validate_request(request), request)
        for action in [
            {"action": "adjust_slider", "identifier": "size", "normalized_position": 0.5},
            {"action": "adjust_slider", "identifier": "size", "element_type": "button", "normalized_position": 0.5},
            {"action": "tap", "identifier": "size", "normalized_position": 0.5},
            {"action": "tap", "label": "", "element_type": "slider"},
        ]:
            with self.subTest(action=action), self.assertRaises(operator.OperatorError):
                operator.validate_request({"bundle_id": "com.apple.Preferences", "actions": [action]})

    def test_scoped_controls_and_search_fields_have_explicit_targets(self):
        request = {"bundle_id": "com.skybridge.compass.ios", "actions": [
            {"action": "tap", "label": "Open", "element_type": "button", "within_identifier": "filePicker"},
            {"action": "tap", "identifier": "tab", "element_type": "button", "child_identifier": "tab"},
            {"action": "type", "label": "Search", "element_type": "search_field", "text": "test.bin"},
        ]}
        self.assertEqual(operator.validate_request(request), request)

    def test_scopes_do_not_replace_the_target_or_allow_empty_values(self):
        for action in [
            {"action": "tap", "within_identifier": "filePicker"},
            {"action": "tap", "label": "Open", "within_identifier": ""},
            {"action": "tap", "label": "Open", "within_identifier": 7},
            {"action": "tap", "label": "Open", "containing_identifier": []},
            {"action": "tap", "label": "Open", "child_identifier": ""},
            {"action": "tap", "label": "Open", "child_identifier": []},
            {"action": "snapshot_tree", "within_identifier": "filePicker"},
        ]:
            with self.subTest(action=action), self.assertRaises(operator.OperatorError):
                operator.validate_request({"bundle_id": "com.skybridge.compass.ios", "actions": [action]})

    def test_invalid_element_types_and_unselected_targets_are_rejected(self):
        for action in [
            {"action": "tap", "label": "File", "element_type": "any"},
            {"action": "tap", "label": "File", "element_type": 9},
            {"action": "tap", "label": "File", "element_type": []},
            {"action": "tap", "element_type": "button"},
            {"action": "snapshot", "element_type": "button"},
        ]:
            with self.subTest(action=action), self.assertRaises(operator.OperatorError):
                operator.validate_request({"bundle_id": "com.skybridge.compass.ios", "actions": [action]})

    def test_runner_plan_keeps_signed_host_and_existing_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source, output = root / "original.xctestrun", root / "operation.xctestrun"
            source.write_bytes(plistlib.dumps({"AppleOperator": {
                "BlueprintName": "AppleOperator", "TestHostPath": "__TESTROOT__/Runner.app",
                "TestBundlePath": "__TESTHOST__/PlugIns/AppleOperator.xctest",
                "UseUITargetAppProvidedByTests": True, "EnvironmentVariables": {"EXISTING": "value"},
            }}))
            original = source.read_bytes()
            request = {"bundle_id": "com.skybridge.compass.ios", "actions": [{"action": "snapshot"}]}
            operator.prepare_xctestrun(source, output, request)
            target = plistlib.loads(output.read_bytes())["AppleOperator"]
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(target["TestHostPath"], str(root / "Runner.app"))
            self.assertEqual(target["TestBundlePath"], "__TESTHOST__/PlugIns/AppleOperator.xctest")
            self.assertEqual(target["EnvironmentVariables"]["EXISTING"], "value")
            self.assertEqual(json.loads(target["EnvironmentVariables"]["SKYBRIDGE_OPERATOR_REQUEST"]), request)
            with self.assertRaises(FileExistsError):
                operator.prepare_xctestrun(source, output, request)

    def test_unrecognized_plan_is_rejected_without_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "other.xctestrun", root / "operation.xctestrun"
            source.write_bytes(plistlib.dumps({"Other": {"BlueprintName": "Other"}}))
            with self.assertRaises(operator.OperatorError):
                operator.prepare_xctestrun(source, output, {})
            self.assertFalse(output.exists())

    def test_plan_cannot_silently_replace_the_product_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "unsafe.xctestrun", root / "operation.xctestrun"
            source.write_bytes(plistlib.dumps({"AppleOperator": {
                "BlueprintName": "AppleOperator", "UseUITargetAppProvidedByTests": True,
                "UITargetAppPath": "/different/SkyBridge.app",
            }}))
            with self.assertRaisesRegex(operator.OperatorError, "already-installed"):
                operator.prepare_xctestrun(source, output, {})
            self.assertFalse(output.exists())

    def test_child_failure_retains_diagnostic_and_nonzero_result(self):
        with self.assertRaisesRegex(operator.OperatorError, "actual child failure"):
            operator.run(["/bin/sh", "-c", "printf 'actual child failure'; exit 7"])


if __name__ == "__main__":
    unittest.main()
