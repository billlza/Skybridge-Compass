#!/usr/bin/env bash
set -euo pipefail

# 简单检查：扫描指定路径内的 Mach-O 文件，验证最小 macOS 版本 <= 目标版本
# 用法：
#   bash Scripts/check_macos_deps.sh [--strict] [path] [min_version]
# 默认：
#   path = dist/SkyBridge\ Compass.app（若存在）否则当前目录
#   min_version = 14.0
# strict:
#   未能解析 Mach-O 最低系统版本时失败；release readiness 使用该模式。

STRICT_MODE=0
if [[ "${1:-}" == "--strict" ]]; then
  STRICT_MODE=1
  shift
fi

ROOT_PATH="${1:-}"
TARGET_VERSION="${2:-14.0}"

if [ -z "$ROOT_PATH" ]; then
  if [ -d "dist/SkyBridge Compass Pro.app" ]; then
    ROOT_PATH="dist/SkyBridge Compass Pro.app"
  else
    ROOT_PATH="."
  fi
fi

ROOT_PATH="$ROOT_PATH" TARGET_VERSION="$TARGET_VERSION" STRICT_MODE="$STRICT_MODE" python3 - <<'PY'
import os
import subprocess
import sys
from pathlib import Path

root = Path(os.environ.get("ROOT_PATH", ""))
target = os.environ.get("TARGET_VERSION", "14.0")
strict_mode = os.environ.get("STRICT_MODE") == "1"
file_tool = os.environ.get("SKYBRIDGE_FILE_TOOL", "/usr/bin/file")
otool_tool = os.environ.get("SKYBRIDGE_OTOOL_TOOL", "/usr/bin/otool")

def parse_version(value: str):
    parts = value.strip().split(".")
    while len(parts) < 2:
        parts.append("0")
    try:
        return tuple(int(p) for p in parts[:2])
    except ValueError:
        print(f"无效版本号: {value}", file=sys.stderr)
        raise SystemExit(1)

target_tuple = parse_version(target)

if not root.exists():
    print(f"检查路径不存在: {root}", file=sys.stderr)
    raise SystemExit(1)

def is_macho(path: Path) -> bool:
    try:
        out = subprocess.check_output([file_tool, "-b", str(path)], text=True).strip()
    except OSError as exc:
        scanner_errors.append((path, f"file tool failed: {exc}"))
        return False
    except subprocess.CalledProcessError as exc:
        scanner_errors.append((path, f"file tool exited {exc.returncode}"))
        return False
    return "Mach-O" in out

def extract_minos_values(path: Path):
    try:
        out = subprocess.check_output([otool_tool, "-l", str(path)], text=True, stderr=subprocess.DEVNULL)
    except OSError as exc:
        scanner_errors.append((path, f"otool failed: {exc}"))
        return []
    except subprocess.CalledProcessError as exc:
        scanner_errors.append((path, f"otool exited {exc.returncode}"))
        return []

    values = []
    command_kind = None
    for line in out.splitlines():
        line = line.strip()
        if line == "cmd LC_BUILD_VERSION":
            command_kind = "build_version"
            continue
        if line == "cmd LC_VERSION_MIN_MACOSX":
            command_kind = "version_min_macosx"
            continue
        if line.startswith("cmd "):
            command_kind = None
            continue

        if command_kind == "build_version" and line.startswith("minos "):
            values.append(line.split("minos ", 1)[1].strip().split()[0])
            command_kind = None
            continue
        if command_kind == "version_min_macosx" and line.startswith("version "):
            values.append(line.split("version ", 1)[1].strip().split()[0])
            command_kind = None
    return values

bad = []
unknown = []
scanner_errors = []

for path in root.rglob("*"):
    if not path.is_file():
        continue
    if path.is_symlink():
        continue
    if not is_macho(path):
        continue
    minos_values = extract_minos_values(path)
    if not minos_values:
        unknown.append(path)
        continue
    for minos in minos_values:
        if parse_version(minos) > target_tuple:
            bad.append((path, minos))

print(f"检查路径: {root}")
print(f"目标最小版本上限: {target}")

if bad:
    print("发现最小版本高于目标上限的二进制：")
    for path, minos in bad:
        print(f"  - {path} (minos {minos})")
    sys.exit(2)

if unknown:
    print("未能解析最小版本的文件（仅提示）：")
    for path in unknown[:20]:
        print(f"  - {path}")
    if len(unknown) > 20:
        print(f"  ... 其余 {len(unknown) - 20} 个省略")
    if strict_mode:
        print("strict 模式要求所有 Mach-O 文件都能解析最低系统版本")
        sys.exit(3)

if scanner_errors:
    print("扫描 Mach-O 文件时工具调用失败：")
    for path, error in scanner_errors[:20]:
        print(f"  - {path}: {error}")
    if len(scanner_errors) > 20:
        print(f"  ... 其余 {len(scanner_errors) - 20} 个省略")
    if strict_mode:
        print("strict 模式要求 file/otool 工具成功检查所有候选文件")
        sys.exit(4)

print("通过：未发现最小版本高于目标上限的二进制")
PY
