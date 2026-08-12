#!/usr/bin/env bash

read_keychain_generic_password() {
  local service="$1"
  local account="$2"
  local err_file="$3"
  local timeout_seconds="${4:-${SKYBRIDGE_SMOKE_KEYCHAIN_TIMEOUT_SECONDS:-${SKYBRIDGE_KEYCHAIN_READ_TIMEOUT_SECONDS:-15}}}"

  python3 - "$service" "$account" "$err_file" "$timeout_seconds" <<'PY'
import pathlib
import subprocess
import sys

service, account, err_file, timeout_raw = sys.argv[1:5]
try:
    timeout_seconds = int(timeout_raw)
except ValueError:
    pathlib.Path(err_file).write_text(
        "status=invalid_timeout\n"
        "operation=security_find_generic_password\n"
        f"service={service}\n"
        f"account={account}\n"
        f"timeout_seconds={timeout_raw}\n"
        f"message=invalid keychain timeout: {timeout_raw}\n"
    )
    raise SystemExit(64)

if timeout_seconds < 1 or timeout_seconds > 600:
    pathlib.Path(err_file).write_text(
        "status=invalid_timeout\n"
        "operation=security_find_generic_password\n"
        f"service={service}\n"
        f"account={account}\n"
        f"timeout_seconds={timeout_seconds}\n"
        "message=keychain timeout must be between 1 and 600 seconds\n"
    )
    raise SystemExit(64)

command = [
    "security",
    "find-generic-password",
    "-s",
    service,
    "-a",
    account,
    "-w",
]

try:
    completed = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout_seconds,
    )
except FileNotFoundError:
    pathlib.Path(err_file).write_text(
        "status=missing_tool\n"
        "operation=security_find_generic_password\n"
        f"service={service}\n"
        f"account={account}\n"
        f"timeout_seconds={timeout_seconds}\n"
        "message=security command not found in PATH\n"
    )
    raise SystemExit(127)
except subprocess.TimeoutExpired:
    pathlib.Path(err_file).write_text(
        "status=timeout\n"
        "operation=security_find_generic_password\n"
        f"service={service}\n"
        f"account={account}\n"
        f"timeout_seconds={timeout_seconds}\n"
        "message=security find-generic-password timed out; unlock Keychain or provide the required SKYBRIDGE_* environment variables\n"
    )
    raise SystemExit(124)

if completed.returncode != 0:
    pathlib.Path(err_file).write_text(
        "status=failed\n"
        "operation=security_find_generic_password\n"
        f"service={service}\n"
        f"account={account}\n"
        f"timeout_seconds={timeout_seconds}\n"
        f"exit_status={completed.returncode}\n"
        f"security_stderr={completed.stderr.strip()}\n"
    )
else:
    pathlib.Path(err_file).write_text("")
if completed.returncode != 0:
    raise SystemExit(completed.returncode)

sys.stdout.write(completed.stdout)
PY
}
