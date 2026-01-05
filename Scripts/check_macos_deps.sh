#!/usr/bin/env bash
set -euo pipefail

# 简单检查：扫描指定路径内的 Mach-O 文件，验证最小 macOS 版本 <= 目标版本
# 用法：
#   bash Scripts/check_macos_deps.sh [path] [min_version]
# 默认：
#   path = dist/SkyBridge\ Compass.app（若存在）否则当前目录
#   min_version = 14.0

ROOT_PATH="${1:-}"
TARGET_VERSION="${2:-14.0}"

if [ -z "$ROOT_PATH" ]; then
  if [ -d "dist/SkyBridge Compass.app" ]; then
    ROOT_PATH="dist/SkyBridge Compass.app"
  else
    ROOT_PATH="."
  fi
fi

ROOT_PATH="$ROOT_PATH" TARGET_VERSION="$TARGET_VERSION" python3 - <<'PY'
import os
import subprocess
import sys
from pathlib import Path

root = Path(os.environ.get("ROOT_PATH", ""))
target = os.environ.get("TARGET_VERSION", "14.0")

def parse_version(value: str):
    parts = value.strip().split(".")
    while len(parts) < 2:
        parts.append("0")
    return tuple(int(p) for p in parts[:2])

target_tuple = parse_version(target)

def is_macho(path: Path) -> bool:
    try:
        out = subprocess.check_output(["/usr/bin/file", "-b", str(path)], text=True).strip()
    except Exception:
        return False
    return "Mach-O" in out

def extract_minos(path: Path):
    try:
        out = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return None
    minos = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("minos "):
            minos = line.split("minos ", 1)[1].strip().split()[0]
            break
        if line.startswith("version "):
            minos = line.split("version ", 1)[1].strip().split()[0]
    return minos

bad = []
unknown = []

for path in root.rglob("*"):
    if not path.is_file():
        continue
    if path.is_symlink():
        continue
    if not is_macho(path):
        continue
    minos = extract_minos(path)
    if not minos:
        unknown.append(path)
        continue
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

print("通过：未发现最小版本高于目标上限的二进制")
PY
