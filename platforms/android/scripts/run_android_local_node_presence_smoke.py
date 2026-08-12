#!/usr/bin/env python3
"""Verify Android local-node Bonjour presence from a Mac host.

The smoke installs and launches the Android debug APK, waits for the app log that
reports `_skybridge._tcp` publication, then uses macOS `dns-sd` to resolve a
matching service with `platform=android`.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_APK = ROOT_DIR / "app/build/outputs/apk/debug/app-debug.apk"
DEFAULT_PACKAGE = "com.skybridge.compass.debug"
PRESENCE_LOG_RE = re.compile(r"Android Bonjour presence active on _skybridge\._tcp port=(\d+)")
PRESENCE_FAILURE_RE = re.compile(r"Android Bonjour presence stopped after startup failure")
FATAL_RUNTIME_RE = re.compile(r"FATAL EXCEPTION")
NSD_TIMEOUT_RE = re.compile(r"NSD registration timed out")
EMULATOR_NAT_RE = re.compile(r"Android emulator NAT is diagnostic-only")
LOCAL_NETWORK_PERMISSION_RE = re.compile(r"ACCESS_LOCAL_NETWORK")
MDNS_ADD_RE = re.compile(r"\[MdnsAdvertiser\] Adding service .*type: _skybridge\._tcp")
MDNS_REMOVE_RE = re.compile(r"\[MdnsAdvertiser\] Removing service")


class SmokeError(RuntimeError):
    def __init__(self, message: str, exit_code: int = 1) -> None:
        super().__init__(message)
        self.exit_code = exit_code


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="adb serial. Required when multiple devices are attached.")
    parser.add_argument("--apk", default=str(DEFAULT_APK), help="APK to install before launch.")
    parser.add_argument("--package", default=DEFAULT_PACKAGE, help="Android application package name.")
    parser.add_argument("--run-dir", help="Artifact directory.")
    parser.add_argument("--skip-install", action="store_true", help="Use an already-installed APK.")
    parser.add_argument("--log-wait-seconds", type=int, default=40)
    parser.add_argument("--browse-seconds", type=int, default=12)
    parser.add_argument("--resolve-timeout-seconds", type=int, default=6)
    return parser.parse_args()


def run_dir_from_args(args: argparse.Namespace) -> Path:
    if args.run_dir:
        return Path(args.run_dir).expanduser().resolve()
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    return ROOT_DIR / "build/interop/android-local-node-presence" / stamp


def command_path(env_name: str, fallback: str) -> str:
    configured = os.environ.get(env_name)
    if configured:
        return configured
    found = shutil.which(fallback)
    if not found:
        raise SmokeError(f"required command not found: {fallback}")
    return found


def run_command(
    args: list[str],
    *,
    artifact: Path | None = None,
    timeout: int | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        args,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    if artifact is not None:
        artifact.write_text(completed.stdout)
    if check and completed.returncode != 0:
        raise SmokeError(
            f"command failed ({completed.returncode}): {' '.join(args)}\n{completed.stdout}"
        )
    return completed


def attached_devices(adb: str) -> list[str]:
    completed = run_command([adb, "devices"], check=True)
    devices: list[str] = []
    for line in completed.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            devices.append(parts[0])
    return devices


def resolve_device(adb: str, requested: str | None) -> str:
    if requested:
        return requested
    devices = attached_devices(adb)
    if len(devices) != 1:
        raise SmokeError(f"expected exactly one adb device, found {len(devices)}: {devices}", exit_code=10)
    return devices[0]


def install_apk(adb: str, device: str, apk: Path, run_dir: Path) -> None:
    if not apk.is_file():
        raise SmokeError(f"APK not found: {apk}")
    completed = run_command(
        [adb, "-s", device, "install", "-r", "-g", "--user", "0", str(apk)],
        artifact=run_dir / "adb-install.txt",
        check=False,
    )
    if completed.returncode == 0:
        return
    if "INSTALL_FAILED_USER_RESTRICTED" in completed.stdout:
        raise SmokeError(
            "Android device rejected APK install with INSTALL_FAILED_USER_RESTRICTED. "
            "Enable/confirm USB app installation on the device, then rerun this smoke.",
            exit_code=20,
        )
    raise SmokeError(f"APK install failed:\n{completed.stdout}")


def launch_app(adb: str, device: str, package: str, run_dir: Path) -> None:
    run_command([adb, "-s", device, "logcat", "-c"], artifact=run_dir / "adb-logcat-clear.txt")
    run_command([adb, "-s", device, "shell", "am", "force-stop", package], artifact=run_dir / "adb-force-stop.txt", check=False)
    completed = run_command(
        [adb, "-s", device, "shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1"],
        artifact=run_dir / "adb-launch.txt",
        check=False,
    )
    if completed.returncode != 0 or "No activities found" in completed.stdout:
        raise SmokeError(f"failed to launch package {package}:\n{completed.stdout}", exit_code=21)


def logcat_dump(adb: str, device: str) -> str:
    completed = run_command(
        [
            adb,
            "-s",
            device,
            "logcat",
            "-d",
            "-v",
            "time",
            "-s",
            "AndroidLocalNode:*",
            "BonjourAdvertiser:*",
            "SkyBridgeApp:*",
            "AndroidRuntime:E",
            "*:S",
        ],
        check=False,
    )
    return completed.stdout


def system_nsd_logcat_dump(adb: str, device: str) -> str:
    completed = run_command(
        [
            adb,
            "-s",
            device,
            "logcat",
            "-d",
            "-v",
            "time",
            "-s",
            "AndroidLocalNode:*",
            "BonjourAdvertiser:*",
            "serviceDiscovery:*",
            "WifiService:*",
            "AndroidRuntime:E",
            "*:S",
        ],
        check=False,
    )
    return completed.stdout


def classify_presence_failure(app_log: str, system_nsd_log: str) -> str:
    if EMULATOR_NAT_RE.search(app_log):
        return "android_emulator_nat_not_bonjour_visible"
    if LOCAL_NETWORK_PERMISSION_RE.search(app_log):
        return "android_local_network_permission_missing"
    if NSD_TIMEOUT_RE.search(app_log):
        mdns_added = MDNS_ADD_RE.search(system_nsd_log) is not None
        mdns_removed = MDNS_REMOVE_RE.search(system_nsd_log) is not None
        if mdns_added and mdns_removed:
            return "nsd_registration_callback_timeout_after_framework_add_remove"
        if mdns_added:
            return "nsd_registration_callback_timeout_after_framework_add"
        return "nsd_registration_callback_timeout_before_framework_add"
    if FATAL_RUNTIME_RE.search(app_log):
        return "android_runtime_fatal_exception"
    return "android_local_node_startup_failure"


def collect_failure_diagnostics(adb: str, device: str, package: str, run_dir: Path, app_log: str) -> str:
    system_nsd_log = system_nsd_logcat_dump(adb, device)
    (run_dir / "android-system-nsd-logcat.txt").write_text(system_nsd_log)
    servicediscovery = run_command(
        [adb, "-s", device, "shell", "dumpsys", "servicediscovery"],
        check=False,
    ).stdout
    (run_dir / "android-dumpsys-servicediscovery.txt").write_text(servicediscovery)
    permissions = run_command(
        [adb, "-s", device, "shell", "dumpsys", "package", package],
        check=False,
    ).stdout
    (run_dir / "android-dumpsys-package.txt").write_text(permissions)
    connectivity = run_command(
        [adb, "-s", device, "shell", "dumpsys", "connectivity"],
        check=False,
    ).stdout
    (run_dir / "android-dumpsys-connectivity.txt").write_text(connectivity)
    ip_addr = run_command(
        [adb, "-s", device, "shell", "ip", "addr"],
        check=False,
    ).stdout
    (run_dir / "android-ip-addr.txt").write_text(ip_addr)
    return classify_presence_failure(app_log, system_nsd_log)


def extract_presence_port(logcat_output: str) -> int | None:
    match = PRESENCE_LOG_RE.search(logcat_output)
    if not match:
        return None
    return int(match.group(1))


def extract_presence_failure(logcat_output: str) -> str | None:
    for line in logcat_output.splitlines():
        if PRESENCE_FAILURE_RE.search(line) or FATAL_RUNTIME_RE.search(line):
            return line.strip()
    return None


def wait_for_presence_log(adb: str, device: str, package: str, run_dir: Path, wait_seconds: int) -> int:
    deadline = time.monotonic() + wait_seconds
    last_log = ""
    while time.monotonic() < deadline:
        last_log = logcat_dump(adb, device)
        (run_dir / "android-logcat.txt").write_text(last_log)
        port = extract_presence_port(last_log)
        if port is not None:
            return port
        failure = extract_presence_failure(last_log)
        if failure is not None:
            classification = collect_failure_diagnostics(
                adb=adb,
                device=device,
                package=package,
                run_dir=run_dir,
                app_log=last_log,
            )
            raise SmokeError(
                "AndroidLocalNode startup failed before publishing Bonjour presence "
                f"(classification={classification}): {failure}",
                exit_code=23,
            )
        time.sleep(1)
    raise SmokeError(
        f"timed out after {wait_seconds}s waiting for AndroidLocalNode presence log",
        exit_code=22,
    )


def run_with_timeout(args: list[str], timeout_seconds: int) -> tuple[int, str]:
    process = subprocess.Popen(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        stdout, _ = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            stdout, _ = process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, _ = process.communicate(timeout=2)
    return process.returncode if process.returncode is not None else 124, stdout


def parse_browse_instances(output: str) -> list[str]:
    instances: list[str] = []
    for line in output.splitlines():
        match = re.search(r"_skybridge\._tcp\.?\s+(.+)$", line)
        if not match:
            continue
        name = match.group(1).strip()
        if name and name not in instances:
            instances.append(name)
    return instances


def browse_instances(dns_sd: str, run_dir: Path, browse_seconds: int) -> list[str]:
    _, output = run_with_timeout([dns_sd, "-B", "_skybridge._tcp", "local"], browse_seconds)
    (run_dir / "dns-sd-browse.txt").write_text(output)
    return parse_browse_instances(output)


def safe_artifact_name(value: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("_")
    return safe[:80] or "instance"


def resolve_instance(dns_sd: str, instance: str, timeout_seconds: int, run_dir: Path) -> str:
    _, output = run_with_timeout([dns_sd, "-L", instance, "_skybridge._tcp", "local"], timeout_seconds)
    (run_dir / f"dns-sd-resolve-{safe_artifact_name(instance)}.txt").write_text(output)
    return output


def output_mentions_port(output: str, port: int) -> bool:
    return re.search(rf"\b{port}\b", output) is not None


def resolved_instance_matches_android_port(output: str, port: int) -> bool:
    return "platform=android" in output and output_mentions_port(output, port)


def verify_mdns(dns_sd: str, run_dir: Path, expected_port: int, browse_seconds: int, resolve_timeout: int) -> str:
    instances = browse_instances(dns_sd, run_dir, browse_seconds)
    if not instances:
        raise SmokeError("dns-sd did not find any _skybridge._tcp instances", exit_code=30)
    for instance in instances:
        resolved = resolve_instance(dns_sd, instance, resolve_timeout, run_dir)
        if resolved_instance_matches_android_port(resolved, expected_port):
            return instance
    raise SmokeError(
        f"dns-sd found _skybridge._tcp instances but none matched platform=android and port={expected_port}: {instances}",
        exit_code=31,
    )


def write_summary(run_dir: Path, lines: list[str]) -> None:
    (run_dir / "summary.txt").write_text("\n".join(lines) + "\n")


def main() -> int:
    args = parse_args()
    run_dir = run_dir_from_args(args)
    run_dir.mkdir(parents=True, exist_ok=True)
    summary = [
        f"cwd={ROOT_DIR}",
        f"run_dir={run_dir}",
        f"date={dt.datetime.now().astimezone().isoformat()}",
    ]
    try:
        adb = command_path("ADB", "adb")
        dns_sd = command_path("DNS_SD", "dns-sd")
        device = resolve_device(adb, args.device)
        apk = Path(args.apk).expanduser().resolve()
        summary.extend([f"adb={adb}", f"dns_sd={dns_sd}", f"device={device}", f"apk={apk}", f"package={args.package}"])

        if not args.skip_install:
            install_apk(adb, device, apk, run_dir)
            summary.append("install_ok=true")
        else:
            summary.append("install_skipped=true")

        launch_app(adb, device, args.package, run_dir)
        summary.append("launch_ok=true")
        port = wait_for_presence_log(adb, device, args.package, run_dir, args.log_wait_seconds)
        summary.append(f"android_presence_port={port}")
        instance = verify_mdns(
            dns_sd,
            run_dir,
            expected_port=port,
            browse_seconds=args.browse_seconds,
            resolve_timeout=args.resolve_timeout_seconds,
        )
        summary.append(f"mdns_android_instance={instance}")
        summary.append("android_local_node_presence_smoke=passed")
        write_summary(run_dir, summary)
        print((run_dir / "summary.txt").read_text(), end="")
        return 0
    except SmokeError as error:
        summary.append(f"android_local_node_presence_smoke=failed")
        summary.append(f"error={error}")
        write_summary(run_dir, summary)
        print(error, file=sys.stderr)
        print(f"summary={run_dir / 'summary.txt'}", file=sys.stderr)
        return error.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
