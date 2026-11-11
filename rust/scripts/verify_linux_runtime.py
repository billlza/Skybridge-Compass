#!/usr/bin/env python3
"""Exercise a built Linux CLI in fresh state, using real processes and a PTY.

No account, production backend, user service installation or display is needed.
This is runtime acceptance for headless operation, not desktop/media acceptance.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import pty
import select
import signal
import subprocess
import tempfile
import time


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def run(binary: Path, state: Path, *arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(binary), "--state-dir", str(state), *arguments],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15,
    )


def failure_json(result: subprocess.CompletedProcess) -> dict:
    require(result.returncode != 0, "command unexpectedly succeeded")
    require(not result.stdout, "failure wrote an ambiguous stdout result")
    payload = json.loads(result.stderr)
    require(payload.get("success") is False, "failure did not report success=false")
    return payload


def wait_healthy(binary: Path, state: Path, process: subprocess.Popen) -> dict:
    deadline = time.monotonic() + 20
    last_error = "no status observed"
    while time.monotonic() < deadline:
        require(process.poll() is None, "agent exited before healthy status")
        result = run(binary, state, "agent", "status", "--json")
        if result.returncode == 0:
            payload = json.loads(result.stdout)
            require(payload["status"] == "healthy", "status command accepted unhealthy runtime")
            return payload
        last_error = failure_json(result)["error"]["message"]
        time.sleep(0.1)
    raise RuntimeError(f"agent did not become healthy: {last_error}")


def stop_agent(process: subprocess.Popen) -> None:
    process.send_signal(signal.SIGTERM)
    require(process.wait(timeout=40) == 0, "SIGTERM did not complete graceful shutdown")


def cleanup_process(process: subprocess.Popen) -> None:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=40)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def pty_read_until(master: int, expected: bytes, process: subprocess.Popen) -> bytes:
    deadline = time.monotonic() + 15
    output = bytearray()
    while time.monotonic() < deadline:
        require(process.poll() is None, "menu exited before expected terminal output")
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            output.extend(os.read(master, 65536))
            if expected in output:
                return bytes(output)
    raise RuntimeError(f"menu did not render {expected!r}")


def verify_terminal(binary: Path, state: Path) -> list[str]:
    require(run(binary, state, "tui").returncode != 0, "menu accepted non-terminal input")
    master, slave = pty.openpty()
    process = subprocess.Popen(
        [str(binary), "--state-dir", str(state), "tui"],
        stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
    )
    os.close(slave)
    try:
        pty_read_until(master, "选择: ".encode(), process)
        # A real read-only operation must reach the selected runtime, then return
        # to the menu. A mutation cancelled by the user must leave state intact.
        os.write(master, b"2\n")
        output = pty_read_until(master, "选择: ".encode(), process)
        require(b"Status: healthy" in output, "menu did not execute live agent status")
        os.write(master, b"20\n")
        pty_read_until(master, "确认".encode(), process)
        os.write(master, b"no\n")
        pty_read_until(master, "选择: ".encode(), process)
        os.write(master, b"q\n")
        require(process.wait(timeout=5) == 0, "menu did not exit cleanly")
    finally:
        cleanup_process(process)
        os.close(master)
    return ["non_terminal_rejected", "pty_live_status", "pty_cancel_mutation", "pty_exit"]


def verify_terminal_agent(binary: Path, state: Path) -> list[str]:
    master, slave = pty.openpty()
    process = subprocess.Popen(
        [str(binary), "--state-dir", str(state), "tui"],
        stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
    )
    os.close(slave)
    try:
        pty_read_until(master, "选择: ".encode(), process)
        os.write(master, b"1\n")
        pty_read_until(master, "确认".encode(), process)
        os.write(master, b"yes\n")
        wait_healthy(binary, state, process)
        process.send_signal(signal.SIGINT)
        pty_read_until(master, "选择: ".encode(), process)
        failure_json(run(binary, state, "agent", "status", "--json"))
        os.write(master, b"q\n")
        require(process.wait(timeout=5) == 0, "foreground agent did not return control to menu")
    finally:
        cleanup_process(process)
        os.close(master)
    return ["pty_foreground_agent_sigint_returns_to_menu"]


def verify(binary: Path) -> dict:
    require(platform.system() == "Linux", "this acceptance script requires Linux")
    checks: list[str] = []
    with tempfile.TemporaryDirectory(prefix="skybridge-linux-runtime-") as directory:
        root = Path(directory)
        state = root / "state with spaces"
        invalid_state = root / "invalid-options"
        invalid = run(binary, invalid_state, "agent", "run", "--discovery-scan-window-seconds", "0")
        require(invalid.returncode != 0 and not invalid_state.exists(), "invalid options changed runtime state")
        checks.append("invalid_options_have_no_effect")
        failure_json(run(binary, state, "agent", "status", "--json"))
        checks.append("missing_agent_fails_closed")
        log_path = root / "process.log"
        with log_path.open("w") as log:
            command = [str(binary), "--state-dir", str(state), "agent", "run", "--no-discovery-scan"]
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            try:
                wait_healthy(binary, state, process)
                health_path = state / "runtime" / "health.json"
                first = json.loads(health_path.read_text())
                require(first["pid"] == process.pid, "health PID did not match real process")
                lease_path = state / "runtime" / "agent-lease.json"
                lease_bytes = lease_path.read_bytes()
                checks.append("real_agent_health_and_pid")
                duplicate = run(binary, state, "agent", "run", "--no-discovery-scan")
                require(duplicate.returncode != 0, "duplicate agent was accepted")
                require("agent_runtime_active" in duplicate.stderr, "duplicate failed for an unrelated reason")
                require(lease_path.read_bytes() == lease_bytes, "duplicate agent overwrote active lease")
                checks.append("exclusive_agent_lock_preserves_owner")
                for path in [state, state / "identity", state / "runtime", state / "logs", state / "identity" / "protocol-signing-key.json"]:
                    require(path.stat().st_mode & 0o077 == 0, f"private runtime path exposes group/other access: {path.name}")
                checks.append("private_state_permissions")
                checks.extend(verify_terminal(binary, state))
                require(not (state / "runtime" / "nearby-discovery-snapshots.json").exists(), "disabled scanner still published discovery")
                checks.append("background_discovery_can_be_disabled")
                stop_agent(process)
                stopped = json.loads(health_path.read_text())
                require(stopped["status"] == "stopping", "shutdown did not publish final health")
                require('"agent.stopped"' in (state / "logs" / "agent.log").read_text(), "shutdown event missing")
                failure_json(run(binary, state, "agent", "status", "--json"))
                checks.append("sigterm_cleanup_rejects_stale_health")
                identity = json.loads((state / "identity" / "device.json").read_text())
                signing_key = (state / "identity" / "protocol-signing-key.json").read_bytes()
            finally:
                cleanup_process(process)
            restarted = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            try:
                wait_healthy(binary, state, restarted)
                second = json.loads(health_path.read_text())
                require(second["instance_id"] != first["instance_id"], "restart reused runtime incarnation")
                restarted_identity = json.loads((state / "identity" / "device.json").read_text())
                # ensure_device_identity -> sync_identity_binding deliberately
                # refreshes device.updated_at on every startup. All other
                # identity/account fields and the actual signing key must stay.
                previous_update = identity["device"].pop("updated_at")
                current_update = restarted_identity["device"].pop("updated_at")
                require(isinstance(previous_update, str) and isinstance(current_update, str), "identity update timestamp missing")
                require(restarted_identity == identity, "restart changed persistent identity binding")
                require((state / "identity" / "protocol-signing-key.json").read_bytes() == signing_key, "restart replaced signing key")
                checks.append("restart_changes_incarnation_preserves_identity")
                failure_json(run(binary, state, "agent", "stop", "--instance-id", first["instance_id"], "--json"))
                require(restarted.poll() is None, "stale stop request killed replacement agent")
                checks.append("stale_stop_does_not_signal_replacement")
                # A damaged session registry must degrade the real runtime and
                # deny normal work, while its owner can still shut it down.
                (state / "runtime" / "sessions.json").write_text("{invalid")
                deadline = time.monotonic() + 10
                while json.loads(health_path.read_text())["status"] != "degraded":
                    require(time.monotonic() < deadline, "invalid session registry was not reflected in health")
                    time.sleep(0.1)
                failure_json(run(binary, state, "agent", "status", "--json"))
                stopped = run(binary, state, "agent", "stop", "--instance-id", second["instance_id"], "--json")
                require(stopped.returncode == 0, f"pidfd stop failed: {stopped.stderr}")
                result = json.loads(stopped.stdout)
                require(result["process_exited"] is True and result["instance_id"] == second["instance_id"], "stop did not bind observed exit to target incarnation")
                require(result["cleanup_verified"] is False, "stop fabricated cleanup proof")
                require(restarted.wait(timeout=5) == 0, "stopped agent did not exit successfully")
                failure_json(run(binary, state, "agent", "stop", "--json"))
                checks.append("pidfd_stop_waits_for_exact_process_exit")
                checks.append("degraded_agent_denies_work_but_can_be_stopped")
            finally:
                cleanup_process(restarted)
        checks.extend(verify_terminal_agent(binary, root / "menu-agent"))
        version = run(binary, state, "version", "--json")
        require(version.returncode == 0, "version failed")
        return {
            "schema_version": 1,
            "success": True,
            "host": {"system": platform.system(), "machine": platform.machine(), "kernel": platform.release()},
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "version": json.loads(version.stdout),
            "checks": checks,
            "scope": "Linux headless process lifecycle and terminal; no desktop/media or cross-device claim",
        }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    # A failed rerun must not leave a stale success receipt at the selected path.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"schema_version": 1, "success": False, "status": "running"}) + "\n")
    try:
        result = verify(args.binary.resolve(strict=True))
    except Exception as error:
        args.output.write_text(json.dumps({"schema_version": 1, "success": False, "error": str(error)}, indent=2) + "\n")
        raise
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"success": True, "checks": len(result["checks"]), "receipt": str(args.output)}))


if __name__ == "__main__":
    main()
