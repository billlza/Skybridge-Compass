#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "$ROOT_DIR/Scripts/test_webrtc_smoke_process_ownership.py"
bash -n "$ROOT_DIR/Scripts/run_real_device_webrtc_smoke.sh"
bash -n "$ROOT_DIR/Scripts/test_real_device_webrtc_process_ownership.sh"
shellcheck -x \
  "$ROOT_DIR/Scripts/run_real_device_webrtc_smoke.sh" \
  "$ROOT_DIR/Scripts/test_real_device_webrtc_process_ownership.sh"

echo "Real-device WebRTC process-ownership tests passed."
