#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PYTHONDONTWRITEBYTECODE=1 \
  /usr/bin/python3 "$ROOT_DIR/Scripts/test_skybridge_core_resource_bundle.py"
