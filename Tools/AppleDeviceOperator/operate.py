#!/usr/bin/env python3
"""Bounded Xcode CLI operations on physical Apple devices; no mirror UI."""
import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile


class OperatorError(RuntimeError):
    pass


ELEMENT_TYPES = {"button", "static_text", "text_field", "secure_text_field", "search_field", "text_view", "scroll_view", "other", "switch", "slider"}


def run(argv, *, timeout=30, log=None):
    """Own the entire child group so a deadline cannot leave a late UI test."""
    if log:
        with Path(log).open("xb") as output:
            return _run(argv, timeout, output)
    return _run(argv, timeout, subprocess.PIPE)


def _run(argv, timeout, output):
    process = subprocess.Popen(argv, stdout=output, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    try:
        text, _ = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise OperatorError("operation interrupted; no completion is claimed; inspect retained result/log") from error
    if process.returncode:
        detail = (text or "").strip()[-2000:] if output == subprocess.PIPE else "inspect the retained operation log"
        raise OperatorError(f"{Path(argv[0]).name} exited {process.returncode}: {detail}")
    return text


def devicectl(arguments):
    with tempfile.TemporaryDirectory(prefix="skybridge-apple-device-") as directory:
        result = Path(directory) / "result.json"
        run(["xcrun", "devicectl", "--timeout", "20", "--quiet", "--json-output", str(result), *arguments])
        document = json.loads(result.read_text())
    if document.get("info", {}).get("outcome") != "success" or not isinstance(document.get("result"), dict):
        raise OperatorError("devicectl did not report a successful structured result")
    return document["result"]


def physical_devices():
    result = devicectl(["list", "devices"])
    if not isinstance(result.get("devices"), list):
        raise OperatorError("devicectl device schema is missing its device list")
    devices = []
    for item in result["devices"]:
        properties = item.get("properties", {})
        hardware = properties.get("hardware", item.get("hardwareProperties", {}))
        if hardware.get("reality") == "simulated":
            continue
        if hardware.get("reality") != "physical":
            raise OperatorError("unrecognized device reality; physical inventory is incomplete")
        state = properties.get("state", item.get("deviceProperties", {}))
        connection = properties.get("connection", item.get("connectionProperties", {}))
        devices.append({"device_id": item["identifier"], "udid": hardware["udid"],
                        "name": state.get("name"), "model": hardware.get("marketingName"),
                        "connection": connection.get("state", connection.get("tunnelState")),
                        "transport": connection.get("transportType"),
                        "developer_mode": state.get("developerModeStatus"),
                        "ui_automation_verified": False})
    return devices


def resolve_device(identifier):
    matches = [d for d in physical_devices() if identifier in (d["device_id"], d["udid"])]
    if len(matches) != 1:
        raise OperatorError("select one physical device_id or UDID from devices")
    device = matches[0]
    # Inventory describes a cached/CoreDevice tunnel state. A closed tunnel is
    # opened on demand by device commands without launching the Device Hub UI.
    probe = devicectl(["device", "info", "lockState", "--device", device["device_id"]])
    if probe.get("deviceIdentifier") != device["device_id"]:
        raise OperatorError("device probe returned a different device identity")
    if probe.get("passcodeRequired") is not False:
        raise OperatorError("unlock the selected physical device before operating it")
    return device


def validate_request(value):
    if not isinstance(value, dict) or set(value) != {"bundle_id", "actions"}:
        raise OperatorError("request must contain only bundle_id and actions")
    bundle = value["bundle_id"]
    if not isinstance(bundle, str) or not bundle or len(bundle) > 255 or any(c.isspace() for c in bundle):
        raise OperatorError("invalid bundle_id")
    actions = value["actions"]
    if not isinstance(actions, list) or not 1 <= len(actions) <= 64:
        raise OperatorError("actions must contain 1..64 operations")
    for action in actions:
        if not isinstance(action, dict) or set(action) - {
            "action", "identifier", "label", "text", "element_type", "within_identifier", "child_identifier", "normalized_position", "normalized_x", "normalized_y"
        }:
            raise OperatorError("unknown UI action fields")
        kind = action.get("action")
        if kind not in {"snapshot", "snapshot_tree", "tap", "tap_at", "type", "swipe_up", "swipe_down", "assert_exists", "adjust_slider"}:
            raise OperatorError("unsupported UI action")
        if kind in {"snapshot", "snapshot_tree"}:
            if set(action) != {"action"}:
                raise OperatorError("snapshot has no selector or text")
            continue
        selectors = [action[k] for k in ("identifier", "label") if k in action]
        unlabeled_slider = (kind == "adjust_slider" and action.get("element_type") == "slider"
                            and action.get("label") == "" and "identifier" not in action)
        if (len(selectors) != 1 or not isinstance(selectors[0], str)
                or (not selectors[0] and not unlabeled_slider) or len(selectors[0]) > 512):
            raise OperatorError("UI action requires exactly one nonempty identifier or label")
        if "element_type" in action:
            element_type = action["element_type"]
            if not isinstance(element_type, str) or element_type not in ELEMENT_TYPES:
                raise OperatorError("unsupported UI element type")
        for key in ("within_identifier", "child_identifier"):
            if key in action and (not isinstance(action[key], str) or not action[key] or len(action[key]) > 512):
                raise OperatorError("UI scope requires a nonempty identifier of at most 512 characters")
        if kind == "type":
            if not isinstance(action.get("text"), str) or len(action["text"].encode()) > 4096:
                raise OperatorError("type requires at most 4096 bytes of text")
        elif "text" in action:
            raise OperatorError("only type accepts text")
        if kind == "adjust_slider":
            position = action.get("normalized_position")
            if (type(position) not in (int, float) or not math.isfinite(position)
                    or not 0 <= position <= 1 or action.get("element_type") != "slider"):
                raise OperatorError("adjust_slider requires a slider and finite normalized_position in 0..1")
        elif "normalized_position" in action:
            raise OperatorError("only adjust_slider accepts normalized_position")
        if kind == "tap_at":
            for coordinate in ("normalized_x", "normalized_y"):
                coordinate_value = action.get(coordinate)
                if type(coordinate_value) not in (int, float) or not math.isfinite(coordinate_value) or not 0 <= coordinate_value <= 1:
                    raise OperatorError("tap_at requires two finite normalized coordinates in 0..1")
        elif "normalized_x" in action or "normalized_y" in action:
            raise OperatorError("only tap_at accepts normalized coordinates")
    if len(json.dumps(value).encode()) > 65536:
        raise OperatorError("UI request exceeds 64 KiB")
    return value


def prepare_xctestrun(source, destination, request):
    source = Path(source).resolve(strict=True)
    document = plistlib.loads(source.read_bytes())
    configured = 0

    def visit(value):
        nonlocal configured
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(source.parent))
        if isinstance(value, list):
            return [visit(item) for item in value]
        if isinstance(value, dict):
            value = {key: visit(item) for key, item in value.items()}
            if value.get("BlueprintName") == "AppleOperator" or str(value.get("TestBundlePath", "")).endswith("/AppleOperator.xctest"):
                if value.get("UseUITargetAppProvidedByTests") is not True or value.get("UITargetAppPath"):
                    raise OperatorError("runner must target the already-installed app, without an app installation dependency")
                environment = value.setdefault("EnvironmentVariables", {})
                environment["SKYBRIDGE_OPERATOR_REQUEST"] = json.dumps(request, ensure_ascii=False)
                configured += 1
            return value
        return value

    document = visit(document)
    if configured != 1:
        raise OperatorError("xctestrun must contain exactly one AppleOperator test target")
    with Path(destination).open("xb") as output:
        plistlib.dump(document, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("devices")
    for name in ("apps", "launch", "screenshot", "build", "run"):
        command = commands.add_parser(name)
        command.add_argument("--device", required=True)
        if name in ("apps", "launch"):
            command.add_argument("--bundle-id", default="com.skybridge.compass.ios")
        if name in ("screenshot", "build", "run"):
            command.add_argument("--out", required=True, type=Path)
        if name == "run":
            command.add_argument("--xctestrun", required=True, type=Path)
            command.add_argument("--actions-file", required=True, type=Path)
            command.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if args.command == "devices":
        return {"success": True, "runtime_target": "apple_development_tools", "devices": physical_devices()}
    device = resolve_device(args.device)
    if args.command == "apps":
        return devicectl(["device", "info", "apps", "--device", device["device_id"], "--bundle-id", args.bundle_id])
    if args.command == "launch":
        result = devicectl(["device", "process", "launch", "--device", device["device_id"], args.bundle_id])
        return {"success": True, "completion": "process_launched", "ui_automation_verified": False, "result": result}
    destination = args.out.resolve()
    if destination.exists():
        raise OperatorError("--out already exists; choose a new evidence path")
    if args.command == "screenshot":
        result = devicectl(["device", "capture", "screenshot", "--device", device["device_id"], "--destination", str(destination)])
        if not destination.is_file() or destination.stat().st_size == 0:
            raise OperatorError("screenshot result is missing or empty")
        return {"success": True, "path": str(destination), "result": result}
    destination.mkdir(parents=True)
    root = Path(__file__).resolve().parent
    if args.command == "build":
        run(["xcodegen", "generate", "--spec", str(root / "project.yml"), "--project", str(destination)], log=destination / "project.log")
        run(["xcodebuild", "build-for-testing", "-project", str(destination / "SkyBridgeAppleOperator.xcodeproj"),
             "-scheme", "AppleOperator", "-destination", "platform=iOS,arch=arm64,id=" + device["udid"],
             "-derivedDataPath", str(destination / "DerivedData"), "-parallel-testing-enabled", "NO"],
            timeout=300, log=destination / "build.log")
        plans = list((destination / "DerivedData/Build/Products").glob("*.xctestrun"))
        if len(plans) != 1:
            raise OperatorError("build did not produce exactly one xctestrun")
        return {"success": True, "completion": "runner_built", "xctestrun": str(plans[0]), "physical_ui_verified": False}
    if not 1 <= args.timeout <= 600:
        raise OperatorError("timeout must be 1..600 seconds")
    request = validate_request(json.loads(args.actions_file.read_text()))
    plan = destination / "operation.xctestrun"
    prepare_xctestrun(args.xctestrun, plan, request)
    result_bundle = destination / "operation.xcresult"
    execution_error = None
    try:
        run(["xcodebuild", "test-without-building", "-xctestrun", str(plan),
             "-destination", "platform=iOS,arch=arm64,id=" + device["udid"], "-resultBundlePath", str(result_bundle),
             "-parallel-testing-enabled", "NO", "-only-testing:AppleOperator/AppleOperatorTests/testOperateInstalledApp"],
            timeout=args.timeout, log=destination / "operation.log")
    except OperatorError as error:
        execution_error = str(error)
        if not (result_bundle / "Info.plist").is_file():
            raise
    attachments = destination / "attachments"
    run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result_bundle), "--output-path", str(attachments)])
    manifest = json.loads((attachments / "manifest.json").read_text())
    paths = [attachments / item["exportedFileName"] for test in manifest for item in test.get("attachments", [])
             if item.get("suggestedHumanReadableName", "").startswith("operator-result")]
    if len(paths) != 1:
        raise OperatorError(execution_error or "expected one structured operator result attachment")
    result = json.loads(paths[0].read_text())
    if result.get("bundle_id") != request["bundle_id"] or result.get("completion") != "ui_actions_executed":
        raise OperatorError("operator attachment is not bound to the requested application")
    if execution_error:
        result["success"] = False
        result["execution_error"] = execution_error
    elif result.get("success") is not True or result.get("executed_actions") != len(request["actions"]):
        raise OperatorError("UI runner did not confirm all requested actions")
    result["evidence"] = str(result_bundle)
    return result


if __name__ == "__main__":
    try:
        result = main()
        failed = result.get("success") is False
        print(json.dumps(result, ensure_ascii=False, indent=2), file=sys.stderr if failed else sys.stdout)
        if failed:
            sys.exit(1)
    except (OperatorError, OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        print(json.dumps({"success": False, "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
