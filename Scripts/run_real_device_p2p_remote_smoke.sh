#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/real_device_p2p_remote_smoke_$(date +%Y%m%d_%H%M%S)}"
IOS_PROJECT="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_BUNDLE_ID="com.skybridge.compass.ios"
IOS_BUILD_DESTINATION="${SKYBRIDGE_IOS_BUILD_DESTINATION:-generic/platform=iOS}"
SMOKE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-240}"
IOS_LAUNCH_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_IOS_LAUNCH_TIMEOUT_SECONDS:-$((SMOKE_TIMEOUT_SECONDS + 60))}"
SMOKE_REMOTE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_REMOTE_DESKTOP_TIMEOUT_SECONDS:-$SMOKE_TIMEOUT_SECONDS}"
SMOKE_MIN_FPS="${SKYBRIDGE_SMOKE_MIN_FPS:-59}"
SMOKE_TARGET_FPS="${SKYBRIDGE_SMOKE_TARGET_FPS:-60}"
SMOKE_SOAK_SECONDS="${SKYBRIDGE_SMOKE_SOAK_SECONDS:-10}"
SMOKE_VIDEO_WIDTH="${SKYBRIDGE_SMOKE_VIDEO_WIDTH:-2056}"
SMOKE_VIDEO_HEIGHT="${SKYBRIDGE_SMOKE_VIDEO_HEIGHT:-1329}"
SMOKE_EXPECT_RENDER_ORIENTATION="${SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION:-upright}"
SMOKE_REQUIRE_SIGNED_KEM_REFRESH="${SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH:-1}"
SMOKE_FORCE_SIGNED_KEM_REFRESH="${SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH:-$SMOKE_REQUIRE_SIGNED_KEM_REFRESH}"
SMOKE_AUTO_APPROVE_PAIRING="${SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING:-1}"
RUN_ID="${SKYBRIDGE_SMOKE_P2P_REMOTE_RUN_ID:-$(date +%Y%m%d%H%M%S)}"
PREFERRED_SUITE="${SB_PQC_PREFERRED_SUITE:-xwing}"
HOST_PREFERRED_SUITE="${SB_PQC_HOST_PREFERRED_SUITE:-$PREFERRED_SUITE}"
IOS_PREFERRED_SUITE="${SB_PQC_IOS_PREFERRED_SUITE:-$PREFERRED_SUITE}"
EXPECTED_TARGET_SUITE="${SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE:-X-Wing}"
HOST_HANDSHAKE_PATTERN="(success .*suite=${EXPECTED_TARGET_SUITE} .*handshakeOnly=1|mac remote established .*suite=${EXPECTED_TARGET_SUITE})"
PRESERVE_INSTALL="${SKYBRIDGE_SMOKE_PRESERVE_INSTALL:-1}"
PQC_TRUST_MODE="${SKYBRIDGE_SMOKE_PQC_TRUST_MODE:-injected}"
SWIFTPM_CACHE_DIR="${SKYBRIDGE_SWIFTPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"
SWIFT_MODULE_CACHE_DIR="${SKYBRIDGE_SWIFT_MODULE_CACHE_DIR:-$ROOT_DIR/.swiftpm-module-cache}"

case "$PQC_TRUST_MODE" in
  user|actual|injected) ;;
  *)
    echo "Unsupported SKYBRIDGE_SMOKE_PQC_TRUST_MODE=$PQC_TRUST_MODE (expected: user, actual, injected)" >&2
    exit 2
    ;;
esac

case "$IOS_LAUNCH_TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    echo "Unsupported SKYBRIDGE_SMOKE_IOS_LAUNCH_TIMEOUT_SECONDS=$IOS_LAUNCH_TIMEOUT_SECONDS (expected positive integer seconds)" >&2
    exit 2
    ;;
  *)
    if (( IOS_LAUNCH_TIMEOUT_SECONDS < 5 )); then
      echo "Unsupported SKYBRIDGE_SMOKE_IOS_LAUNCH_TIMEOUT_SECONDS=$IOS_LAUNCH_TIMEOUT_SECONDS (minimum 5 seconds)" >&2
      exit 2
    fi
    ;;
esac

mkdir -p "$ARTIFACT_DIR" "$SWIFTPM_CACHE_DIR" "$SWIFT_MODULE_CACHE_DIR"

pick_real_device_id() {
  python3 - <<'PY'
import re
import subprocess

def pick_from_xctrace():
    output = subprocess.check_output(["xcrun", "xctrace", "list", "devices"], text=True)
    in_devices = False
    for line in output.splitlines():
        stripped = line.strip()
        if stripped == "== Devices ==":
            in_devices = True
            continue
        if stripped.startswith("== ") and stripped != "== Devices ==":
            in_devices = False
        if not in_devices or not stripped or "Mac" in stripped:
            continue
        match = re.search(r"\(([0-9A-Fa-f-]{20,})\)$", stripped)
        if match:
            print(match.group(1))
            return True
    return False

def pick_from_devicectl():
    try:
        output = subprocess.check_output(
            ["xcrun", "devicectl", "list", "devices"],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False

    candidates = []
    for line in output.splitlines():
        if "available" not in line or "paired" not in line:
            continue
        match = re.search(r"([0-9A-Fa-f-]{8}(?:-[0-9A-Fa-f-]{4}){3}-[0-9A-Fa-f-]{12})", line)
        if match:
            candidates.append((0 if "iPad" in line else 1, match.group(1)))

    for _, identifier in sorted(candidates):
        print(identifier)
        return True
    return False

if pick_from_xctrace() or pick_from_devicectl():
    raise SystemExit(0)
raise SystemExit("No connected real iOS device found.")
PY
}

IOS_DEVICE_ID="${SKYBRIDGE_REAL_DEVICE_ID:-$(pick_real_device_id)}"
MAC_TARGET_NAME="${SKYBRIDGE_SMOKE_MAC_TARGET_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"
HOST_STATUS="$ARTIFACT_DIR/mac.status.log"
HOST_PQC_REPORT="$ARTIFACT_DIR/mac.pqc.json"
HOST_STDOUT="$ARTIFACT_DIR/mac.stdout.log"
MAC_SMOKE_SOURCE_FRAME_A="$ARTIFACT_DIR/mac-smoke-source-a.png"
MAC_SMOKE_SOURCE_FRAME_B="$ARTIFACT_DIR/mac-smoke-source-b.png"
IOS_STATUS_NAME="ios-p2p-remote-${RUN_ID}.status.log"
IOS_STATUS_LOCAL="$ARTIFACT_DIR/$IOS_STATUS_NAME"
IOS_STATUS_APP_CACHE_LOCAL="$ARTIFACT_DIR/${IOS_STATUS_NAME%.status.log}.app-cache.status.log"
IOS_STATUS_CONSOLE_SNAPSHOT="$ARTIFACT_DIR/${IOS_STATUS_NAME%.status.log}.console.status.log"
IOS_CONSOLE_STDERR="$ARTIFACT_DIR/ios-console.stderr.log"
IOS_BUILD_LOG="$ARTIFACT_DIR/ios-build.log"
LAUNCH_RESULT_JSON="$ARTIFACT_DIR/ios-launch.json"
DEVICE_INFO_TXT="$ARTIFACT_DIR/device-info.txt"
HOST_PID=""
IOS_CONSOLE_PID=""
COMMON_REMOTE_SMOKE_FAILURE_PATTERN='classic fallback|compatibility fallback|fallback=true|legacyFallback=true|pipeline=stillImageFallback|orientation=verticalFlip|orientation=horizontalFlip|orientation=inverted|renderOrientation=verticalFlip|renderOrientation=horizontalFlip|renderOrientation=inverted|已立即回退|已回退到|fallback producer|perf=extreme.*h264|h264.*perf=extreme|suite_rejected_unknown|wireId=0x0000|wireId=0X0000|unknown suite|unknown-suite|signed LAN KEM refresh rejected|signed LAN KEM refresh failed|PIB-1 protocol identity binding failed|PIB-1 protocol identity binding rejected|PIB-1 protocol identity binding timed out|lifecycle=request>rejected|lifecycle=missing-kem>failed|lifecycle=identity-oob>failed|lifecycle=identity-oob>timeout|render-main-path-failed|strict-media-failed'
IOS_REMOTE_SMOKE_FAILURE_PATTERN="failed stage=|${COMMON_REMOTE_SMOKE_FAILURE_PATTERN}|crossNetwork=1|audioRxPlaybackDrop=[1-9][0-9]*|audioRxJitterEvicted=[1-9][0-9]*|audioRxUnderflow=[1-9][0-9]*|audioRxRebuffer=[1-9][0-9]*|jitterEvicted=[1-9][0-9]*|playbackDrop=[1-9][0-9]*|datagrams=[1-9][0-9][0-9]+ .*probable=rx-decode-stalled|HEVC 连续失败|临时降级 H\\.264|codec=h264"
HOST_REMOTE_SMOKE_FAILURE_PATTERN="${COMMON_REMOTE_SMOKE_FAILURE_PATTERN}|failed stage=(identity|handshake|remote-desktop|remote-control|media)|mac-sck-start .*codec=h264|mac-sck-first-frame codec=h264|mac-sck-tx .*codec=h264 .*capturesAudio=false|mac-sck-encode-failed .*capturesAudio=false|mac-sck-tx .*encodeFailures=[1-9][0-9]*|mac-stream-config .*damage=true .*perf=extreme"

cleanup() {
  if [[ -n "$IOS_CONSOLE_PID" ]]; then
    kill "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
    wait "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$HOST_PID" ]]; then
    kill "$HOST_PID" >/dev/null 2>&1 || true
    wait "$HOST_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

timestamp_utc() {
  date -u +"[%Y-%m-%dT%H:%M:%SZ]"
}

append_host_status() {
  printf '%s %s\n' "$(timestamp_utc)" "$*" >>"$HOST_STATUS"
}

append_ios_status() {
  printf '%s %s\n' "$(timestamp_utc)" "$*" >>"$IOS_STATUS_LOCAL"
}

fail_if_host_exited() {
  local label="$1"
  if [[ -n "$HOST_PID" ]] && ! kill -0 "$HOST_PID" >/dev/null 2>&1; then
    append_host_status "failed stage=mac-host phase=process-exited label=${label// /_}"
    echo "macOS host process exited while waiting for ${label}: ${HOST_STATUS}" >&2
    echo "---- macOS status tail ($HOST_STATUS) ----" >&2
    tail -n 80 "$HOST_STATUS" >&2 2>/dev/null || true
    echo "---- host stdout tail ($HOST_STDOUT) ----" >&2
    tail -n 80 "$HOST_STDOUT" >&2 2>/dev/null || true
    return 1
  fi
}

wait_for_file_pattern() {
  local path="$1"
  local pattern="$2"
  local timeout_seconds="$3"
  local label="$4"
  local started_at
  started_at="$(date +%s)"
  while true; do
    fail_if_host_exited "$label" || return 1
    if [[ -n "$IOS_CONSOLE_PID" ]] \
      && [[ -f "$IOS_STATUS_LOCAL" ]] \
      && grep -qE "$IOS_REMOTE_SMOKE_FAILURE_PATTERN" "$IOS_STATUS_LOCAL"; then
      echo "Detected iOS failure while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 80 "$IOS_STATUS_LOCAL" >&2 || true
      tail -n 40 "$IOS_CONSOLE_STDERR" >&2 || true
      return 1
    fi
    if [[ -n "$IOS_CONSOLE_PID" ]] && ! kill -0 "$IOS_CONSOLE_PID" >/dev/null 2>&1; then
      echo "iOS console process exited while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 80 "$IOS_STATUS_LOCAL" >&2 || true
      tail -n 80 "$IOS_CONSOLE_STDERR" >&2 || true
      return 1
    fi
    if [[ -f "$HOST_STATUS" ]] && grep -qE "$HOST_REMOTE_SMOKE_FAILURE_PATTERN" "$HOST_STATUS"; then
      echo "Detected macOS host media failure while waiting for ${label}: ${HOST_STATUS}" >&2
      copy_ios_status
      echo "---- macOS status tail ($HOST_STATUS) ----" >&2
      tail -n 80 "$HOST_STATUS" >&2 2>/dev/null || true
      echo "---- iOS status tail ($IOS_STATUS_LOCAL) ----" >&2
      tail -n 80 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      return 1
    fi
    if [[ -f "$path" ]] && grep -qE "$pattern" "$path"; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${path}" >&2
      copy_ios_status
      echo "---- iOS status tail ($IOS_STATUS_LOCAL) ----" >&2
      tail -n 80 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      tail -n 40 "$path" >&2 || true
      return 1
    fi
    sleep 1
  done
}

copy_ios_status() {
  if [[ -f "$IOS_STATUS_LOCAL" ]]; then
    cp "$IOS_STATUS_LOCAL" "$IOS_STATUS_CONSOLE_SNAPSHOT" 2>/dev/null || true
  else
    rm -f "$IOS_STATUS_CONSOLE_SNAPSHOT"
  fi

  python3 - "$IOS_DEVICE_ID" "$IOS_BUNDLE_ID" "Library/Caches/$IOS_STATUS_NAME" "$IOS_STATUS_APP_CACHE_LOCAL" <<'PY'
import os
import subprocess
import sys

device_id, bundle_id, source, destination = sys.argv[1:]
temporary_destination = f"{destination}.tmp"
try:
    os.remove(temporary_destination)
except FileNotFoundError:
    pass
command = [
    "xcrun",
    "devicectl",
    "device",
    "copy",
    "from",
    "--device",
    device_id,
    "--domain-type",
    "appDataContainer",
    "--domain-identifier",
    bundle_id,
    "--source",
    source,
    "--destination",
    temporary_destination,
]
try:
    completed = subprocess.run(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=15,
        check=False,
    )
    if completed.returncode == 0 and os.path.exists(temporary_destination):
        os.replace(temporary_destination, destination)
    else:
        try:
            os.remove(temporary_destination)
        except FileNotFoundError:
            pass
except subprocess.TimeoutExpired:
    try:
        os.remove(temporary_destination)
    except FileNotFoundError:
        pass
PY

  if [[ -f "$IOS_STATUS_CONSOLE_SNAPSHOT" && -f "$IOS_STATUS_APP_CACHE_LOCAL" ]]; then
    {
      printf '%s\n' "# source=devicectl-console"
      sed -n 'p' "$IOS_STATUS_CONSOLE_SNAPSHOT"
      printf '\n'
      printf '%s\n' "# source=app-cache"
      sed -n 'p' "$IOS_STATUS_APP_CACHE_LOCAL"
    } >"$IOS_STATUS_LOCAL.merged"
    mv "$IOS_STATUS_LOCAL.merged" "$IOS_STATUS_LOCAL"
  elif [[ -f "$IOS_STATUS_APP_CACHE_LOCAL" ]]; then
    cp "$IOS_STATUS_APP_CACHE_LOCAL" "$IOS_STATUS_LOCAL" 2>/dev/null || true
  fi
}

verify_mac_smoke_capture_source_visible() {
  local first="$MAC_SMOKE_SOURCE_FRAME_A"
  local second="$MAC_SMOKE_SOURCE_FRAME_B"
  local proof

  if ! command -v screencapture >/dev/null 2>&1; then
    append_host_status "failed stage=mac-host phase=smoke-source-preflight reason=missing-screencapture"
    echo "macOS screencapture command is unavailable; cannot prove the smoke source is visible before iPad launch." >&2
    return 1
  fi

  screencapture -x "$first"
  sleep 0.45
  screencapture -x "$second"

  if ! proof="$(swift - "$first" "$second" 2>&1 <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: swift - first.png second.png")
}

func loadImage(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("unable to decode screenshot \(path)")
    }
    return image
}

func rgbaPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    pixels.withUnsafeMutableBytes { storage in
        guard let context = CGContext(
            data: storage.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            fail("unable to allocate screenshot comparison context")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return pixels
}

let first = loadImage(CommandLine.arguments[1])
let second = loadImage(CommandLine.arguments[2])
let width = min(first.width, second.width)
let height = min(first.height, second.height)
guard width >= 160, height >= 120 else {
    fail("screenshot is too small for smoke source preflight: \(width)x\(height)")
}

let firstPixels = rgbaPixels(first, width: width, height: height)
let secondPixels = rgbaPixels(second, width: width, height: height)
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
let gridColumns = 42
let gridRows = 24
let xStart = width / 8
let xEnd = max(xStart + 1, width * 7 / 8)
let yStart = height / 8
let yEnd = max(yStart + 1, height * 7 / 8)
var changedSamples = 0
var totalSamples = 0
var deltaTotal = 0

for row in 0..<gridRows {
    let y = yStart + ((yEnd - yStart) * row / max(1, gridRows - 1))
    for column in 0..<gridColumns {
        let x = xStart + ((xEnd - xStart) * column / max(1, gridColumns - 1))
        let offset = y * bytesPerRow + x * bytesPerPixel
        let redDelta = abs(Int(firstPixels[offset]) - Int(secondPixels[offset]))
        let greenDelta = abs(Int(firstPixels[offset + 1]) - Int(secondPixels[offset + 1]))
        let blueDelta = abs(Int(firstPixels[offset + 2]) - Int(secondPixels[offset + 2]))
        let delta = redDelta + greenDelta + blueDelta
        deltaTotal += delta
        totalSamples += 1
        if delta >= 36 {
            changedSamples += 1
        }
    }
}

let changedRatio = Double(changedSamples) / Double(max(1, totalSamples))
let meanDelta = Double(deltaTotal) / Double(max(1, totalSamples))
print(String(format: "changedRatio=%.3f meanDelta=%.1f samples=%d", changedRatio, meanDelta, totalSamples))

guard changedRatio >= 0.25, meanDelta >= 8.0 else {
    fail(String(format: "smoke source was not visibly dynamic in screencapture: changedRatio=%.3f meanDelta=%.1f samples=%d", changedRatio, meanDelta, totalSamples))
}
SWIFT
)"; then
    append_host_status "failed stage=mac-host phase=smoke-source-preflight reason=capture-not-dynamic screenshotA=$(basename "$first") screenshotB=$(basename "$second")"
    echo "$proof" >&2
    echo "Mac smoke source is not visible/dynamic in screencapture. Unlock the Mac display, keep the desktop visible, and rerun before using the iPad smoke." >&2
    return 1
  fi

  append_host_status "smoke-capture-source captureVerified=1 $proof screenshotA=$(basename "$first") screenshotB=$(basename "$second")"
}

wait_for_ios_status_pattern() {
  local pattern="$1"
  local timeout_seconds="$2"
  local label="$3"
  local started_at
  local last_status_mtime=0
  local last_status_update_at=0
  started_at="$(date +%s)"
  last_status_update_at="$started_at"
  while true; do
    fail_if_host_exited "$label" || return 1
    local now
    now="$(date +%s)"
    if [[ -f "$IOS_STATUS_LOCAL" ]]; then
      local current_status_mtime
      current_status_mtime="$(stat -f %m "$IOS_STATUS_LOCAL" 2>/dev/null || echo 0)"
      if (( current_status_mtime > last_status_mtime )); then
        last_status_mtime="$current_status_mtime"
        last_status_update_at="$now"
      elif (( now - last_status_update_at >= 60 )); then
        echo "Timed out waiting for fresh iOS status while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
        tail -n 80 "$IOS_STATUS_LOCAL" >&2 || true
        tail -n 40 "$IOS_CONSOLE_STDERR" >&2 || true
        return 1
      fi
    fi
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE "$IOS_REMOTE_SMOKE_FAILURE_PATTERN" "$IOS_STATUS_LOCAL"; then
      echo "Detected failure while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 80 "$IOS_STATUS_LOCAL" >&2 || true
      tail -n 40 "$IOS_CONSOLE_STDERR" >&2 || true
      return 1
    fi
    if [[ -f "$HOST_STATUS" ]] && grep -qE "$HOST_REMOTE_SMOKE_FAILURE_PATTERN" "$HOST_STATUS"; then
      echo "Detected macOS host media failure while waiting for ${label}: ${HOST_STATUS}" >&2
      tail -n 80 "$HOST_STATUS" >&2 || true
      tail -n 80 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      return 1
    fi
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE "$pattern" "$IOS_STATUS_LOCAL"; then
      return 0
    fi
    if [[ -n "$IOS_CONSOLE_PID" ]] && ! kill -0 "$IOS_CONSOLE_PID" >/dev/null 2>&1; then
      echo "iOS console process exited while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 80 "$IOS_STATUS_LOCAL" >&2 || true
      tail -n 80 "$IOS_CONSOLE_STDERR" >&2 || true
      return 1
    fi
    if (( now - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 80 "$IOS_STATUS_LOCAL" >&2 || true
      tail -n 40 "$IOS_CONSOLE_STDERR" >&2 || true
      return 1
    fi
    sleep 2
  done
}

validate_remote_desktop_route_evidence() {
  python3 - "$HOST_STATUS" "$IOS_STATUS_LOCAL" <<'PY'
import re
import sys

host_path, ios_path = sys.argv[1:]

def fail(message):
    raise SystemExit(f"remote route validation failed: {message}")

def metric(line, key):
    match = re.search(rf"(?:^|\s){re.escape(key)}=([^\s]+)", line)
    return match.group(1).strip() if match else None

with open(ios_path, "r", encoding="utf-8", errors="replace") as handle:
    ios_lines = handle.readlines()
with open(host_path, "r", encoding="utf-8", errors="replace") as handle:
    host_lines = handle.readlines()

route_lines = [line for line in ios_lines if "ios-lan-remote-route " in line]
if not route_lines:
    fail(f"no ios-lan-remote-route evidence in {ios_path}")
route_ready_lines = [line for line in ios_lines if "ios-lan-remote-route-ready " in line]
if not route_ready_lines:
    fail(f"no ios-lan-remote-route-ready evidence in {ios_path}")

lan_main_route = [
    line for line in route_lines
    if metric(line, "addressClass") in ("lan-direct", "bonjour-service") and metric(line, "peerToPeer") == "false"
]
if not lan_main_route:
    fail("no routable LAN direct or Bonjour infrastructure route with peerToPeer=false")
lan_ready_route = [
    line for line in route_ready_lines
    if metric(line, "resolvedAddressClass") == "lan-direct" and metric(line, "resolvedPeerToPeer") == "false"
]
if not lan_ready_route:
    fail("no verified LAN hostPort route-ready evidence with resolvedAddressClass=lan-direct resolvedPeerToPeer=false")

bad_ios_routes = [
    line.strip()
    for line in route_lines
    if metric(line, "addressClass") == "link-local" or metric(line, "peerToPeer") == "true"
]
if bad_ios_routes:
    fail("iOS LAN route used link-local/peer-to-peer path: " + bad_ios_routes[-1])
bad_ios_ready_routes = [
    line.strip()
    for line in route_ready_lines
    if metric(line, "resolvedAddressClass") != "lan-direct" or metric(line, "resolvedPeerToPeer") != "false"
]
if bad_ios_ready_routes:
    fail("iOS LAN ready route was not verified routable hostPort: " + bad_ios_ready_routes[-1])

bad_mac_peer = [
    line.strip()
    for line in host_lines
    if ("mac remote" in line or "mac-remote" in line or "mac-stream-config" in line)
    and re.search(r"(?:^|\s)peer=(?:peer:|host:|ip:)?\[?(?:fe80:|169\.254\.)", line.lower())
]
if bad_mac_peer:
    fail("macOS remote tx peer was link-local/peer-to-peer: " + bad_mac_peer[-1])

print(
    "remote route validation passed: "
    f"routeSamples={len(route_lines)} readySamples={len(route_ready_lines)} lanMain={len(lan_main_route)} peerToPeer=0 linkLocal=0"
)
PY
}

validate_remote_desktop_performance_window() {
  python3 - "$HOST_STATUS" "$IOS_STATUS_LOCAL" "$SMOKE_MIN_FPS" "$SMOKE_TARGET_FPS" "$SMOKE_SOAK_SECONDS" "$SMOKE_VIDEO_WIDTH" "$SMOKE_VIDEO_HEIGHT" "$SMOKE_EXPECT_RENDER_ORIENTATION" <<'PY'
import datetime as dt
import math
import re
import sys

host_path, ios_path, min_fps_raw, target_fps_raw, soak_raw, width_raw, height_raw, expected_orientation = sys.argv[1:]
min_fps = float(min_fps_raw)
target_fps = float(target_fps_raw)
max_transport_fps = target_fps + 3.0
sck_cadence_catch_up_limit = 2
sender_cadence_catch_up_limit = 3
bounded_missed_cadence_slots_limit = 0
strict_mac_sender_queue_limit = 6
max_sck_source_frame_age_ms = 34.0
max_sck_source_frame_repeat = 3
hevc_burst_headroom_multiplier = 8
hevc_single_chunk_encoded_budget_bytes = 256 * 1024 - 36 - 28 - 36
soak_seconds = float(soak_raw)
expected_frame = f"{int(width_raw)}x{int(height_raw)}"
minimum_window_samples = max(1, int(soak_seconds) - 2)

def fail(message):
    raise SystemExit(f"remote performance window validation failed: {message}")

def parse_iso_timestamp(line):
    match = re.match(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?)Z\]", line)
    if not match:
        return None
    stamp = match.group(1)
    if "." in stamp:
        whole, fraction = stamp.split(".", 1)
        stamp = f"{whole}.{(fraction + '000000')[:6]}"
        return dt.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=dt.timezone.utc)
    return dt.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)

local_log_tz = dt.datetime.now().astimezone().tzinfo or dt.timezone.utc

def parse_console_timestamp(line, anchor_utc):
    match = re.match(r"^\[(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?\]", line)
    if not match or anchor_utc is None:
        return None
    fraction = match.group(4) or ""
    microsecond = int((fraction + "000000")[:6])
    anchor_local = anchor_utc.astimezone(local_log_tz)
    candidate_local = anchor_local.replace(
        hour=int(match.group(1)),
        minute=int(match.group(2)),
        second=int(match.group(3)),
        microsecond=microsecond,
    )
    candidate_utc = candidate_local.astimezone(dt.timezone.utc)
    if (candidate_utc - anchor_utc).total_seconds() > 12 * 60 * 60:
        candidate_utc -= dt.timedelta(days=1)
    elif (anchor_utc - candidate_utc).total_seconds() > 12 * 60 * 60:
        candidate_utc += dt.timedelta(days=1)
    return candidate_utc

def parse_window_timestamp(line, anchor_utc):
    return parse_iso_timestamp(line) or parse_console_timestamp(line, anchor_utc)

def metric(line, key):
    match = re.search(rf"(?:^|\s){re.escape(key)}=([^\s]+)", line)
    return match.group(1).strip() if match else None

def float_metric(line, key):
    value = metric(line, key)
    if value is None:
        fail(f"missing {key}: {line.strip()}")
    try:
        return float(value)
    except ValueError:
        fail(f"invalid {key}={value}: {line.strip()}")

def int_metric(line, key):
    value = metric(line, key)
    if value is None:
        fail(f"missing {key}: {line.strip()}")
    try:
        return int(value)
    except ValueError:
        fail(f"invalid {key}={value}: {line.strip()}")

with open(ios_path, "r", encoding="utf-8", errors="replace") as handle:
    ios_lines = handle.readlines()

pass_candidates = [
    (idx, timestamp)
    for idx, line in enumerate(ios_lines)
    if "remote-desktop-pass " in line
    for timestamp in [parse_iso_timestamp(line)]
    if timestamp is not None
]
if not pass_candidates:
    fail(f"no remote-desktop-pass marker in {ios_path}")
pass_index, pass_time = max(pass_candidates, key=lambda item: item[1])
pass_line = ios_lines[pass_index]
reported_window_seconds = float_metric(pass_line, "windowSeconds")
if reported_window_seconds + 0.5 < soak_seconds:
    fail(f"reported pass window shorter than requested soak: seconds={reported_window_seconds:.2f} soak={soak_seconds}")
reported_window_fps = float_metric(pass_line, "windowFPS")
reported_window_rx_fps = float_metric(pass_line, "windowRxFps")
if reported_window_fps < min_fps:
    fail(f"iOS aggregate display windowFPS below {min_fps}: {pass_line.strip()}")
if reported_window_rx_fps < min_fps:
    fail(f"iOS aggregate rx windowRxFps below {min_fps}: {pass_line.strip()}")
if int_metric(pass_line, "windowDisplayedFrames") <= 0:
    fail(f"iOS pass marker did not report displayed frames: {pass_line.strip()}")
if int_metric(pass_line, "windowReceivedFrames") <= 0:
    fail(f"iOS pass marker did not report received frames: {pass_line.strip()}")
two_second_required = int_metric(pass_line, "twoSecondRequiredFrames")
if two_second_required < math.ceil(min_fps * 2):
    fail(f"iOS two-second cadence requirement is too low: {pass_line.strip()}")
if int_metric(pass_line, "min2sDisplayFrames") < two_second_required:
    fail(f"iOS worst two-second display cadence below requirement: {pass_line.strip()}")
if int_metric(pass_line, "min2sRxFrames") < two_second_required:
    fail(f"iOS worst two-second receive cadence below requirement: {pass_line.strip()}")
rolling_display_cadence = metric(pass_line, "rollingDisplayCadencePass") or metric(pass_line, "rollingCadencePass")
if rolling_display_cadence != "1":
    fail(f"iOS rolling display cadence did not pass: {pass_line.strip()}")
rolling_rx_cadence = metric(pass_line, "rollingRxCadencePass") or metric(pass_line, "rollingCadencePass")
if rolling_rx_cadence != "1":
    fail(f"iOS rolling receive cadence did not pass: {pass_line.strip()}")
rolling_combined_cadence = metric(pass_line, "rollingCombinedCadencePass") or metric(pass_line, "rollingCadencePass")
if rolling_combined_cadence != "1":
    fail(f"iOS rolling combined display/receive cadence did not pass: {pass_line.strip()}")
if metric(pass_line, "rxFrameClock") != "source-cadence+metal-delivery":
    fail(f"iOS receive cadence did not expose source-cadence plus Metal-delivery evidence: {pass_line.strip()}")
if int_metric(pass_line, "last2sSourceFrames") < two_second_required:
    fail(f"iOS source-frame cadence below requirement: {pass_line.strip()}")
if int_metric(pass_line, "last2sMetalDeliveryFrames") < two_second_required:
    fail(f"iOS Metal-delivery cadence below requirement: {pass_line.strip()}")
if int_metric(pass_line, "last2sSocketRxFrames") <= 0:
    fail(f"iOS socket-arrival telemetry was missing from the receive cadence report: {pass_line.strip()}")
start_candidates = [
    (idx, timestamp)
    for idx, line in enumerate(ios_lines)
    if "remote-desktop pass-window-start " in line
    for timestamp in [parse_iso_timestamp(line)]
    if timestamp is not None and timestamp <= pass_time
]
if not start_candidates:
    fail("no pass-window-start before remote-desktop-pass")
start_index, start_time = max(start_candidates, key=lambda item: item[1])
if start_time is None:
    fail("pass window markers are missing ISO timestamps")
if (pass_time - start_time).total_seconds() + 0.5 < soak_seconds:
    fail(f"pass window shorter than requested soak: start={start_time} pass={pass_time} soak={soak_seconds}")

pass_time_upper = pass_time + dt.timedelta(seconds=1)
window_lines = [
    line for idx, line in enumerate(ios_lines)
    for timestamp in [parse_window_timestamp(line, pass_time)]
    if start_index <= idx <= pass_index and timestamp is not None and start_time <= timestamp <= pass_time_upper
]
ios_status_count = 0
audio_status_samples = 0
audio_recv_start = None
audio_recv_end = None
audio_decoded_start = None
audio_decoded_end = None
audio_played_start = None
audio_played_end = None
metal_count = 0
metal_sample_ms = 0
metal_draw_callbacks = 0
metal_submitted = 0
metal_displayed = 0
metal_direct_bgra = 0
metal_coalesced_before_draw = 0
metal_realtime_replacement_before_draw = 0
metal_realtime_replacement_reason_samples = 0
metal_realtime_replacement_reason_bad = 0
metal_manual_draw = 0
metal_queue_backpressure = 0
metal_queue_capacity_max = 0
metal_queue_depth_max = 0
metal_frame_age_max_ms = 0.0
metal_frame_age_samples = 0
metal_display_link_pump_fps = 0
lan_rx_count = 0
frame_budget_ms = 1000.0 / max(min_fps, 1.0)
max_raw_chunk_gap_ms = frame_budget_ms * 12.0
lan_rx_sample_ms = 0
lan_rx_screen_frames = 0
lan_rx_sbc2_frames = 0
lan_rx_sbc2_chunks = 0
lan_rx_max_screen_fps = 0.0
lan_rx_max_gap_ms = 0.0
lan_rx_source_samples = 0
lan_rx_source_gap_max_ms = 0.0
lan_rx_source_to_read_max_ms = 0.0
lan_rx_source_to_read_unsynced_clock_samples = 0
lan_rx_raw_chunks = 0
lan_rx_read_ahead_samples = 0
lan_rx_screen_delivery_samples = 0
lan_rx_screen_delivery_strict_samples = 0
lan_rx_screen_delivery_attempted = 0
lan_rx_screen_delivery_delivered = 0
lan_rx_screen_delivery_backpressure = 0
lan_rx_screen_delivery_queue_depth_max = 0
lan_rx_screen_delivery_delay_max_ms = 0.0
lan_rx_raw_chunk_gap_max_ms = 0.0
lan_rx_raw_chunk_main_hop_max_ms = 0.0
lan_rx_complete_frames_per_drain_max = 0
for line in window_lines:
    if "remote-desktop status " in line:
        ios_status_count += 1
        if metric(line, "corePass") != "1":
            fail(f"iOS core media gate fell out of pass state inside final window: {line.strip()}")
        if metric(line, "frame") != expected_frame:
            fail(f"iOS frame size is not {expected_frame}: {line.strip()}")
        if metric(line, "pipeline") != "metalRenderer":
            fail(f"iOS renderer is not Metal: {line.strip()}")
        if metric(line, "renderOrientation") != expected_orientation:
            fail(f"iOS render orientation is not {expected_orientation}: {line.strip()}")
        for key in ("audioRxPlaybackDrop", "audioRxJitterEvicted", "audioRxUnderflow", "audioRxRebuffer"):
            if int_metric(line, key) != 0:
                fail(f"iOS audio {key} was nonzero: {line.strip()}")
        audio_recv = int_metric(line, "audioRxRecv")
        audio_decoded = int_metric(line, "audioRxDecoded")
        audio_played = int_metric(line, "audioRxPlayed")
        if audio_recv > 0 or audio_decoded > 0 or audio_played > 0:
            audio_status_samples += 1
            if audio_recv_start is None:
                audio_recv_start = audio_recv
                audio_decoded_start = audio_decoded
                audio_played_start = audio_played
            audio_recv_end = audio_recv
            audio_decoded_end = audio_decoded
            audio_played_end = audio_played
    if "Metal render telemetry:" in line:
        metal_count += 1
        metal_sample_ms += int_metric(line, "sampleMs")
        metal_draw_callbacks += int_metric(line, "drawCallbacks")
        metal_submitted += int_metric(line, "submitted")
        metal_displayed += int_metric(line, "displayed")
        metal_direct_bgra += int_metric(line, "directBGRA")
        metal_coalesced_before_draw += int_metric(line, "coalescedBeforeDraw")
        metal_realtime_replacement_before_draw += int_metric(line, "realtimeReplacementBeforeDraw")
        replacement_reason = metric(line, "realtimeReplacementReason")
        if replacement_reason:
            metal_realtime_replacement_reason_samples += 1
            if replacement_reason != "none":
                metal_realtime_replacement_reason_bad += 1
        metal_manual_draw += int_metric(line, "manualDraw")
        metal_queue_capacity_max = max(metal_queue_capacity_max, int_metric(line, "queueCapacity"))
        metal_queue_depth_max = max(metal_queue_depth_max, int_metric(line, "queueDepthMax"))
        metal_display_link_target_fps = int_metric(line, "displayLinkTargetFPS")
        metal_display_link_pump_fps = max(metal_display_link_pump_fps, int_metric(line, "displayLinkPumpFPS"))
        if metal_display_link_target_fps < int(math.ceil(min_fps)):
            fail(f"Metal displayLinkTargetFPS is below the strict FPS gate: {line.strip()}")
        if int_metric(line, "displayLinkPumpFPS") < metal_display_link_target_fps:
            fail(f"Metal displayLinkPumpFPS is below the render target FPS: {line.strip()}")
        if metric(line, "displayLink") != "mtkview-native":
            fail(f"Metal display driver is not the strict MTKView native path: {line.strip()}")
        if metric(line, "displayCadence") != "strict-60-native-pump-catch-up-vsync":
            fail(f"Metal display cadence is not the strict 60Hz MTKView native-vsync path: {line.strip()}")
        frame_age_value = metric(line, "frameAgeMs")
        if frame_age_value and frame_age_value != "-":
            try:
                metal_frame_age_max_ms = max(metal_frame_age_max_ms, float(frame_age_value))
                metal_frame_age_samples += 1
            except ValueError:
                fail(f"invalid Metal frameAgeMs={frame_age_value}: {line.strip()}")
        if int_metric(line, "ciFallback") != 0:
            fail(f"Metal CI fallback rendered frames were nonzero: {line.strip()}")
        metal_queue_backpressure += int_metric(line, "queueBackpressure")
        for key in ("queueDrop", "drawableSkip", "inflightSkip", "failureSkip"):
            if int_metric(line, key) != 0:
                fail(f"Metal {key} was nonzero: {line.strip()}")
    if "ios-lan-remote-rx " in line:
        lan_rx_count += 1
        lan_rx_sample_ms += int_metric(line, "sampleMs")
        lan_rx_screen_frames += int_metric(line, "screenFrames")
        lan_rx_sbc2_frames += int_metric(line, "sbc2Frames")
        lan_rx_sbc2_chunks += int_metric(line, "sbc2Chunks")
        lan_rx_max_screen_fps = max(lan_rx_max_screen_fps, float_metric(line, "screenFPS"))
        lan_rx_max_gap_ms = max(lan_rx_max_gap_ms, float_metric(line, "maxGapMs"))
        lan_rx_source_samples += int_metric(line, "sourceSamples")
        lan_rx_source_gap_max_ms = max(lan_rx_source_gap_max_ms, float_metric(line, "sourceGapMaxMs"))
        lan_rx_source_to_read_max_ms = max(lan_rx_source_to_read_max_ms, float_metric(line, "sourceToReadMaxMs"))
        if metric(line, "sourceToReadClock") == "remote-wall-clock-unsynced":
            lan_rx_source_to_read_unsynced_clock_samples += 1
        lan_rx_raw_chunks += int_metric(line, "rawChunks")
        lan_rx_raw_chunk_gap_max_ms = max(lan_rx_raw_chunk_gap_max_ms, float_metric(line, "rawChunkGapMaxMs"))
        lan_rx_raw_chunk_main_hop_max_ms = max(lan_rx_raw_chunk_main_hop_max_ms, float_metric(line, "rawChunkMainHopMaxMs"))
        lan_rx_complete_frames_per_drain_max = max(lan_rx_complete_frames_per_drain_max, int_metric(line, "completeFramesPerDrainMax"))
        if metric(line, "screenWire") != "sbc2-chunked-v1":
            fail(f"iOS LAN receive did not use sbc2-chunked-v1: {line.strip()}")
        if metric(line, "readAhead") != "stream-parser-low-latency-8k-4frame-drain-budget":
            fail(f"iOS LAN receive did not prove low-latency read-ahead and bounded drain: {line.strip()}")
        lan_rx_read_ahead_samples += 1
        screen_delivery = metric(line, "screenDelivery")
        if screen_delivery is not None:
            lan_rx_screen_delivery_samples += 1
        if screen_delivery == "immediate-decode-metal-feed-direct":
            lan_rx_screen_delivery_strict_samples += 1
        lan_rx_screen_delivery_attempted += int_metric(line, "screenDeliveryAttempted")
        lan_rx_screen_delivery_delivered += int_metric(line, "screenDeliveryDelivered")
        lan_rx_screen_delivery_backpressure += int_metric(line, "screenDeliveryBackpressure")
        lan_rx_screen_delivery_queue_depth_max = max(lan_rx_screen_delivery_queue_depth_max, int_metric(line, "screenDeliveryQueueDepthMax"))
        lan_rx_screen_delivery_delay_max_ms = max(lan_rx_screen_delivery_delay_max_ms, float_metric(line, "screenDeliveryDelayMaxMs"))

if ios_status_count == 0:
    fail("no iOS remote-desktop status samples inside final pass window")
if metal_count == 0:
    fail("no Metal render telemetry inside final pass window")
if lan_rx_count == 0:
    fail("no iOS LAN receive telemetry inside final pass window")
if ios_status_count < minimum_window_samples:
    fail(f"too few iOS status samples inside final pass window: count={ios_status_count} required={minimum_window_samples}")
if metal_count < minimum_window_samples:
    fail(f"too few Metal render telemetry samples inside final pass window: count={metal_count} required={minimum_window_samples}")
if lan_rx_count < minimum_window_samples:
    fail(f"too few iOS LAN receive telemetry samples inside final pass window: count={lan_rx_count} required={minimum_window_samples}")
if metal_sample_ms <= 0:
    fail("Metal render telemetry did not report a positive aggregate sample window")
if metal_frame_age_samples <= 0:
    fail("Metal render telemetry did not report frameAgeMs evidence inside final pass window")
if lan_rx_sample_ms <= 0:
    fail("iOS LAN receive telemetry did not report a positive aggregate sample window")
lan_rx_screen_fps = lan_rx_screen_frames * 1000.0 / lan_rx_sample_ms
if lan_rx_screen_fps < min_fps:
    fail(f"iOS LAN receive aggregate screenFPS below {min_fps}: frames={lan_rx_screen_frames} sampleMs={lan_rx_sample_ms} fps={lan_rx_screen_fps:.1f} maxGapMs={lan_rx_max_gap_ms:.1f}")
if lan_rx_screen_fps > max_transport_fps:
    fail(f"iOS LAN receive aggregate screenFPS exceeded strict target: fps={lan_rx_screen_fps:.1f} target={target_fps:.1f}")
if lan_rx_sbc2_frames <= 0:
    fail(f"iOS LAN receive did not report SBC2 screen frames inside final pass window: screenFrames={lan_rx_screen_frames} sbc2Frames={lan_rx_sbc2_frames}")
if lan_rx_sbc2_chunks < lan_rx_sbc2_frames:
    fail(f"iOS LAN receive reported fewer SBC2 chunks than frames: sbc2Chunks={lan_rx_sbc2_chunks} sbc2Frames={lan_rx_sbc2_frames}")
if lan_rx_source_samples <= 0:
    fail("iOS LAN receive did not expose source timestamp correlation inside final pass window")
if lan_rx_source_gap_max_ms > 100.0:
    fail(f"iOS LAN source timestamp gap exceeded 100ms inside final pass window: sourceGapMaxMs={lan_rx_source_gap_max_ms:.1f}")
if lan_rx_source_to_read_max_ms > 100.0 and lan_rx_source_to_read_unsynced_clock_samples != lan_rx_count:
    fail(f"iOS LAN source-to-read latency exceeded 100ms inside final pass window: sourceToReadMaxMs={lan_rx_source_to_read_max_ms:.1f}")
if lan_rx_raw_chunks <= 0:
    fail("iOS LAN receive did not report raw NWConnection receive chunks inside final pass window")
if lan_rx_read_ahead_samples != lan_rx_count:
    fail(f"iOS LAN receive read-ahead samples did not cover every telemetry line: readAhead={lan_rx_read_ahead_samples} lanRx={lan_rx_count}")
if lan_rx_screen_delivery_samples != lan_rx_count:
    fail(f"iOS LAN screen delivery samples did not cover every telemetry line: screenDelivery={lan_rx_screen_delivery_samples} lanRx={lan_rx_count}")
if lan_rx_screen_delivery_strict_samples != lan_rx_count:
    fail(f"iOS LAN screen delivery was not strict decoded-to-Metal 60Hz feed for every telemetry line: strictScreenDelivery={lan_rx_screen_delivery_strict_samples} lanRx={lan_rx_count}")
if lan_rx_screen_delivery_delivered <= 0:
    fail("iOS LAN screen delivery did not report delivered frames inside final pass window")
if lan_rx_screen_delivery_attempted < lan_rx_screen_delivery_delivered:
    fail(f"iOS LAN screen delivery accepted more frames than attempted: attempted={lan_rx_screen_delivery_attempted} delivered={lan_rx_screen_delivery_delivered}")
lan_rx_screen_delivery_fps = lan_rx_screen_delivery_delivered * 1000.0 / lan_rx_sample_ms
if lan_rx_screen_delivery_fps < min_fps:
    fail(f"iOS LAN screen delivery FPS below {min_fps}: delivered={lan_rx_screen_delivery_delivered} sampleMs={lan_rx_sample_ms} fps={lan_rx_screen_delivery_fps:.1f}")
if lan_rx_screen_delivery_queue_depth_max > 1:
    fail(f"iOS LAN direct screen delivery queued frames instead of immediate Metal feed: screenDeliveryQueueDepthMax={lan_rx_screen_delivery_queue_depth_max}")
if lan_rx_screen_delivery_delay_max_ms > 100.0:
    fail(f"iOS LAN screen delivery delay exceeded 100ms inside final pass window: screenDeliveryDelayMaxMs={lan_rx_screen_delivery_delay_max_ms:.1f}")
if lan_rx_raw_chunk_gap_max_ms > max_raw_chunk_gap_ms:
    fail(f"iOS LAN raw receive chunk gap exceeded 12-frame bounded receive budget inside final pass window: rawChunkGapMaxMs={lan_rx_raw_chunk_gap_max_ms:.1f} budgetMs={max_raw_chunk_gap_ms:.1f}")
if lan_rx_raw_chunk_main_hop_max_ms > 100.0:
    fail(f"iOS LAN raw receive MainActor handoff exceeded 100ms inside final pass window: rawChunkMainHopMaxMs={lan_rx_raw_chunk_main_hop_max_ms:.1f}")
if lan_rx_complete_frames_per_drain_max > 4:
    fail(f"iOS LAN parser drain submitted too many complete screen frames for bounded 4-frame drain: completeFramesPerDrainMax={lan_rx_complete_frames_per_drain_max}")
if metal_direct_bgra != metal_submitted:
    fail(f"Metal direct BGRA frames did not match submitted frames: directBGRA={metal_direct_bgra} submitted={metal_submitted}")
metal_submitted_fps = metal_submitted * 1000.0 / metal_sample_ms
metal_displayed_fps = metal_displayed * 1000.0 / metal_sample_ms
metal_draw_callback_fps = metal_draw_callbacks * 1000.0 / metal_sample_ms
if metal_draw_callback_fps < min_fps:
    fail(f"Metal aggregate drawCallbackFPS below {min_fps}: drawCallbacks={metal_draw_callbacks} sampleMs={metal_sample_ms} fps={metal_draw_callback_fps:.1f}")
max_draw_callback_fps = max(float(metal_display_link_pump_fps), target_fps) + 2.0
if metal_draw_callback_fps > max_draw_callback_fps:
    fail(f"Metal aggregate drawCallbackFPS exceeded native pump budget: drawCallbacks={metal_draw_callbacks} sampleMs={metal_sample_ms} fps={metal_draw_callback_fps:.1f} pumpFPS={metal_display_link_pump_fps} target={target_fps:.1f}")
if metal_submitted_fps < min_fps:
    fail(f"Metal aggregate submittedFPS below {min_fps}: submitted={metal_submitted} sampleMs={metal_sample_ms} fps={metal_submitted_fps:.1f}")
if metal_displayed_fps < min_fps:
    fail(f"Metal aggregate displayFPS below {min_fps}: displayed={metal_displayed} sampleMs={metal_sample_ms} fps={metal_displayed_fps:.1f}")
if metal_submitted_fps > max_transport_fps:
    fail(f"Metal aggregate submittedFPS exceeded strict target: submitted={metal_submitted} sampleMs={metal_sample_ms} fps={metal_submitted_fps:.1f} target={target_fps:.1f}")
if metal_displayed_fps > max_transport_fps:
    fail(f"Metal aggregate displayFPS exceeded strict target: displayed={metal_displayed} sampleMs={metal_sample_ms} fps={metal_displayed_fps:.1f} target={target_fps:.1f}")
max_allowed_metal_coalesced = 0
if metal_coalesced_before_draw > max_allowed_metal_coalesced:
    fail(f"Metal realtime coalescedBeforeDraw was nonzero inside final pass window: coalesced={metal_coalesced_before_draw} allowed={max_allowed_metal_coalesced} submitted={metal_submitted}")
if metal_realtime_replacement_before_draw != metal_coalesced_before_draw:
    fail(f"Metal realtime replacement evidence did not match coalescedBeforeDraw inside final pass window: replacement={metal_realtime_replacement_before_draw} coalesced={metal_coalesced_before_draw}")
if metal_coalesced_before_draw > 0 and metal_realtime_replacement_reason_samples <= 0:
    fail("Metal realtime replacement was nonzero without structured replacement reason inside final pass window")
if metal_realtime_replacement_reason_bad != 0:
    fail(f"Metal realtime replacement reported unexpected reason inside final pass window: badReasons={metal_realtime_replacement_reason_bad}")
if metal_manual_draw != 0:
    fail(f"Metal manualDraw was nonzero inside final pass window: manualDraw={metal_manual_draw}")
if metal_queue_capacity_max > 3:
    fail(f"Metal queueCapacity exceeded bounded 3-frame realtime render queue inside final pass window: queueCapacity={metal_queue_capacity_max}")
if metal_queue_depth_max > 3:
    fail(f"Metal queueDepthMax exceeded bounded 3-frame realtime render queue inside final pass window: queueDepthMax={metal_queue_depth_max}")
if metal_frame_age_max_ms > 100.0:
    fail(f"Metal frameAgeMs exceeded 100ms inside final pass window: frameAgeMs={metal_frame_age_max_ms:.1f}")

with open(host_path, "r", encoding="utf-8", errors="replace") as handle:
    host_lines = handle.readlines()

encoder_config_seen = False
encoder_key_interval = 0
encoder_key_duration_ms = 0
encoder_requested_gop = 0
encoder_cadence_catch_up_limit = 0
encoder_rate_limit_bytes_per_second = 0
encoder_burst_limit_bytes = 0
encoder_burst_window_ms = 0
encoder_data_rate_limits_status = -1
encoder_data_rate_limits_readback_status = -1
encoder_data_rate_limits_applied = 0
encoder_readback_burst_limit_bytes = 0
encoder_readback_burst_window_ms = 0
encoder_low_latency_rate_control = "missing"
encoder_max_frame_delay_count = 0
encoder_maximum_real_time_frame_rate = 0
encoder_single_chunk_budget_bytes = 0
for line in host_lines:
    timestamp = parse_iso_timestamp(line)
    if timestamp is None or timestamp > pass_time:
        continue
    if "mac-sck-encoder " in line and "codec=hevc" in line and "capturesAudio=false" in line:
        encoder_config_seen = True
        encoder_key_interval = int_metric(line, "keyInterval")
        encoder_key_duration_ms = int_metric(line, "keyDurationMs")
        encoder_requested_gop = int_metric(line, "requestedGOP")
        encoder_cadence_catch_up_limit = int_metric(line, "cadenceCatchUpLimit")
        encoder_max_frame_delay_count = int_metric(line, "maxFrameDelayCount")
        encoder_maximum_real_time_frame_rate = int_metric(line, "maximumRealTimeFrameRate")
        encoder_rate_limit_bytes_per_second = int_metric(line, "dataRateLimitBytesPerSecond")
        encoder_burst_limit_bytes = int_metric(line, "dataRateBurstLimitBytes")
        encoder_burst_window_ms = int_metric(line, "dataRateBurstWindowMs")
        encoder_data_rate_limits_status = int_metric(line, "dataRateLimitsStatus")
        encoder_data_rate_limits_readback_status = int_metric(line, "dataRateLimitsReadbackStatus")
        encoder_data_rate_limits_applied = int_metric(line, "dataRateLimitsApplied")
        encoder_readback_burst_limit_bytes = int_metric(line, "dataRateReadbackBurstLimitBytes")
        encoder_readback_burst_window_ms = int_metric(line, "dataRateReadbackBurstWindowMs")
        encoder_single_chunk_budget_bytes = int_metric(line, "singleChunkHEVCBudgetBytes")
        encoder_low_latency_rate_control = metric(line, "lowLatencyRateControl") or "false"
        if metric(line, "lowLatency") != "true":
            fail(f"Mac HEVC encoder was not in low-latency strict mode: {line.strip()}")

if not encoder_config_seen:
    fail("no Mac HEVC encoder configuration telemetry before final pass")
expected_encoder_gop = max(60, int(round(target_fps)))
if encoder_key_interval != expected_encoder_gop or encoder_requested_gop != expected_encoder_gop:
    fail(
        "Mac HEVC encoder GOP drifted from strict 1s cadence: "
        f"requestedGOP={encoder_requested_gop} keyInterval={encoder_key_interval} expected={expected_encoder_gop}"
    )
if encoder_key_duration_ms < 900 or encoder_key_duration_ms > 1100:
    fail(f"Mac HEVC encoder keyframe duration is not ~1s: keyDurationMs={encoder_key_duration_ms}")
if encoder_cadence_catch_up_limit != sck_cadence_catch_up_limit:
    fail(f"Mac HEVC SCK cadence recovery limit was not the bounded strict producer path: cadenceCatchUpLimit={encoder_cadence_catch_up_limit} expected={sck_cadence_catch_up_limit}")
if encoder_max_frame_delay_count != 3:
    fail(f"Mac HEVC 2K60 encoder delay window did not prove the bounded three-frame VideoToolbox path: maxFrameDelayCount={encoder_max_frame_delay_count}")
if encoder_maximum_real_time_frame_rate != min(int(round(target_fps)) * sck_cadence_catch_up_limit, 120):
    fail(f"Mac HEVC encoder did not expose the bounded realtime catch-up rate: maximumRealTimeFrameRate={encoder_maximum_real_time_frame_rate}")
if encoder_low_latency_rate_control not in ("true", "false"):
    fail(f"Mac HEVC encoder did not expose VideoToolbox low-latency rate-control selection: lowLatencyRateControl={encoder_low_latency_rate_control}")
if encoder_single_chunk_budget_bytes != hevc_single_chunk_encoded_budget_bytes:
    fail(f"Mac HEVC encoder did not expose the SBC2 single-chunk payload budget: singleChunkHEVCBudgetBytes={encoder_single_chunk_budget_bytes} expected={hevc_single_chunk_encoded_budget_bytes}")
if encoder_burst_window_ms != int(round(1000.0 / target_fps)):
    fail(f"Mac HEVC encoder short-window burst cap duration drifted from the single-frame transport budget: dataRateBurstWindowMs={encoder_burst_window_ms}")
expected_encoder_burst_limit_bytes = min(
    max(
        ((encoder_rate_limit_bytes_per_second + int(round(target_fps)) - 1) // int(round(target_fps))) * hevc_burst_headroom_multiplier,
        128 * 1024,
    ),
    hevc_single_chunk_encoded_budget_bytes,
)
if encoder_burst_limit_bytes != expected_encoder_burst_limit_bytes:
    fail(
        "Mac HEVC encoder short-window burst cap drifted from the single-chunk transport budget with bounded headroom: "
        f"dataRateLimitBytesPerSecond={encoder_rate_limit_bytes_per_second} "
        f"dataRateBurstLimitBytes={encoder_burst_limit_bytes} expected={expected_encoder_burst_limit_bytes}"
    )
if encoder_data_rate_limits_status != 0 or encoder_data_rate_limits_readback_status != 0 or encoder_data_rate_limits_applied != 1:
    fail(f"Mac HEVC encoder DataRateLimits were not accepted and read back by VideoToolbox: status={encoder_data_rate_limits_status} readbackStatus={encoder_data_rate_limits_readback_status} applied={encoder_data_rate_limits_applied}")
if encoder_readback_burst_limit_bytes != expected_encoder_burst_limit_bytes or encoder_readback_burst_window_ms != encoder_burst_window_ms:
    fail(f"Mac HEVC encoder DataRateLimits readback did not match strict budget: readbackBurstBytes={encoder_readback_burst_limit_bytes} readbackBurstWindowMs={encoder_readback_burst_window_ms}")

host_window_start = start_time + dt.timedelta(seconds=1)
sck_count = 0
tx_count = 0
sck_sample_ms = 0
sck_encoded_frames = 0
sck_captured_frames = 0
sck_meaningful_frames = 0
sck_source_frame_age_max_ms = 0.0
sck_source_frame_repeat_max = 0
tx_sample_ms = 0
tx_sent_frames = 0
tx_chunked_frames = 0
tx_sent_chunks = 0
tx_max_chunks_per_frame = 0
tx_backpressure = 0
tx_raw_backpressure = 0
tx_ordered_throttle = 0
tx_queue_backlog = 0
tx_queued_max = 0
tx_inflight_max = 0
tx_content_backlog_max = 0
tx_content_backlog_limit = 0
tx_content_backlog_bytes_max = 0
tx_content_backlog_byte_limit = 0
tx_max_frames_per_drain = 0
tx_schedule_budget_max = 0
tx_missed_cadence_slots_max = 0
tx_content_backlog_full = 0
tx_oldest_content_backlog_ms = 0.0
tx_queue_age_max_ms = 0.0
tx_dequeued_age_max_ms = 0.0
tx_max_send_ms = 0.0
tx_schedule_gap_max_ms = 0.0
tx_schedule_jitter_max_ms = 0.0
tx_completion_gap_max_ms = 0.0
tx_content_callback_gap_max_ms = 0.0
tx_content_actor_hop_max_ms = 0.0
tx_encoded_to_submit_max_ms = 0.0
tx_submit_gap_max_ms = 0.0
tx_clock_fire_to_drain_max_ms = 0.0
tx_max_sent_fps = 0.0
tx_stale_queue_catch_up = 0
tx_chunk_cap_bytes = 0
tx_writer_clock_ok = 0
tx_send_scheduler_ok = 0
tx_wire_batch_single_frames = 0
tx_wire_batch_multi_frames = 0
tx_wire_single_unbatched_frames = 0
sck_cadence_timer_fires = 0
sck_cadence_submitted = 0
sck_cadence_catch_up_frames = 0
sck_cadence_batch_max = 0
min_capture_fps = None
min_meaningful_fps = None
for line in host_lines:
    timestamp = parse_iso_timestamp(line)
    if timestamp is None or timestamp < host_window_start or timestamp > pass_time:
        continue
    if "mac-sck-tx " in line and "codec=hevc" in line and "capturesAudio=false" in line:
        sck_count += 1
        capture_fps = float_metric(line, "captureFPS")
        meaningful_fps = float_metric(line, "meaningfulFPS")
        min_capture_fps = capture_fps if min_capture_fps is None else min(min_capture_fps, capture_fps)
        min_meaningful_fps = meaningful_fps if min_meaningful_fps is None else min(min_meaningful_fps, meaningful_fps)
        sck_sample_ms += int_metric(line, "sampleMs")
        sck_captured_frames += int_metric(line, "captured")
        sck_meaningful_frames += int_metric(line, "meaningful")
        sck_encoded_frames += int_metric(line, "encoded")
        sck_source_frame_age_max_ms = max(sck_source_frame_age_max_ms, float_metric(line, "sourceFrameAgeMaxMs"))
        sck_source_frame_repeat_max = max(sck_source_frame_repeat_max, int_metric(line, "sourceFrameRepeatMax"))
        if metric(line, "visible") != expected_frame:
            fail(f"Mac SCK visible size is not {expected_frame}: {line.strip()}")
        if int_metric(line, "encodeFailures") != 0:
            fail(f"Mac HEVC encode failures were nonzero: {line.strip()}")
        sck_cadence_timer_fires += int_metric(line, "cadenceTimerFires")
        sck_cadence_submitted += int_metric(line, "cadenceSubmitted")
        sck_cadence_catch_up_frames += int_metric(line, "cadenceCatchUpFrames")
        sck_cadence_batch_max = max(sck_cadence_batch_max, int_metric(line, "cadenceBatchMax"))
    if "mac-remote-frame-tx " in line:
        tx_count += 1
        tx_sample_ms += int_metric(line, "sampleMs")
        tx_sent_frames += int_metric(line, "sent")
        tx_chunked_frames += int_metric(line, "chunkedFrames")
        tx_sent_chunks += int_metric(line, "sentChunks")
        line_sent_frames = int_metric(line, "sent")
        line_wire_batch_single_frames = int_metric(line, "wireBatchSingleFrames")
        line_wire_batch_multi_frames = int_metric(line, "wireBatchMultiFrames")
        line_wire_single_unbatched_frames = int_metric(line, "wireSingleUnbatchedFrames")
        tx_wire_batch_single_frames += line_wire_batch_single_frames
        tx_wire_batch_multi_frames += line_wire_batch_multi_frames
        tx_wire_single_unbatched_frames += line_wire_single_unbatched_frames
        tx_max_chunks_per_frame = max(tx_max_chunks_per_frame, int_metric(line, "maxChunksPerFrame"))
        line_backpressure = int_metric(line, "backpressure")
        line_raw_backpressure = int_metric(line, "rawBackpressure")
        line_ordered_throttle = int_metric(line, "orderedThrottle")
        line_queue_backlog = int_metric(line, "queueBacklog")
        tx_backpressure += line_backpressure
        tx_raw_backpressure += line_raw_backpressure
        tx_ordered_throttle += line_ordered_throttle
        tx_queue_backlog += line_queue_backlog
        tx_queued_max = max(tx_queued_max, int_metric(line, "queuedMax"))
        tx_inflight_max = max(tx_inflight_max, int_metric(line, "inFlightMax"))
        tx_content_backlog_max = max(tx_content_backlog_max, int_metric(line, "contentBacklogMax"))
        tx_content_backlog_limit = max(tx_content_backlog_limit, int_metric(line, "contentBacklogLimit"))
        tx_content_backlog_bytes_max = max(tx_content_backlog_bytes_max, int_metric(line, "contentBacklogBytesMax"))
        tx_content_backlog_byte_limit = max(tx_content_backlog_byte_limit, int_metric(line, "contentBacklogByteLimit"))
        tx_max_frames_per_drain = max(tx_max_frames_per_drain, int_metric(line, "maxFramesPerDrain"))
        tx_schedule_budget_max = max(tx_schedule_budget_max, int_metric(line, "scheduleBudgetMax"))
        tx_missed_cadence_slots_max = max(tx_missed_cadence_slots_max, int_metric(line, "missedCadenceSlotsMax"))
        tx_content_backlog_full += int_metric(line, "contentBacklogFull")
        tx_oldest_content_backlog_ms = max(tx_oldest_content_backlog_ms, float_metric(line, "oldestContentBacklogMs"))
        tx_queue_age_max_ms = max(tx_queue_age_max_ms, float_metric(line, "queueAgeMaxMs"))
        tx_dequeued_age_max_ms = max(tx_dequeued_age_max_ms, float_metric(line, "dequeuedAgeMaxMs"))
        tx_max_send_ms = max(tx_max_send_ms, float_metric(line, "maxSendMs"))
        tx_schedule_gap_max_ms = max(tx_schedule_gap_max_ms, float_metric(line, "scheduleGapMaxMs"))
        tx_schedule_jitter_max_ms = max(tx_schedule_jitter_max_ms, float_metric(line, "scheduleJitterMaxMs"))
        tx_completion_gap_max_ms = max(tx_completion_gap_max_ms, float_metric(line, "completionGapMaxMs"))
        tx_content_callback_gap_max_ms = max(tx_content_callback_gap_max_ms, float_metric(line, "contentCallbackGapMaxMs"))
        tx_content_actor_hop_max_ms = max(tx_content_actor_hop_max_ms, float_metric(line, "contentActorHopMaxMs"))
        tx_encoded_to_submit_max_ms = max(tx_encoded_to_submit_max_ms, float_metric(line, "encodedToSubmitMaxMs"))
        tx_submit_gap_max_ms = max(tx_submit_gap_max_ms, float_metric(line, "submitGapMaxMs"))
        tx_clock_fire_to_drain_max_ms = max(tx_clock_fire_to_drain_max_ms, float_metric(line, "clockFireToDrainMaxMs"))
        tx_max_sent_fps = max(tx_max_sent_fps, float_metric(line, "sentFPS"))
        tx_stale_queue_catch_up += int_metric(line, "staleQueueCatchUp")
        tx_chunk_cap_bytes = max(tx_chunk_cap_bytes, int_metric(line, "chunkCapBytes"))
        if metric(line, "transport") != "sbc2-chunked-v1":
            fail(f"Mac remote tx did not use sbc2-chunked-v1: {line.strip()}")
        if metric(line, "source") != "encoded-direct-pump":
            fail(f"Mac remote tx did not prove direct encoded-frame handoff to the sender pump: {line.strip()}")
        if line_sent_frames > 0 and metric(line, "chunkSend") not in ("single-unbatched", "batch-single", "batch-multi", "batch-mixed"):
            fail(f"Mac remote tx did not expose a real Network.framework send mode for SBC2 frames: {line.strip()}")
        if (
            line_wire_single_unbatched_frames > 0
            and line_wire_batch_multi_frames == 0
            and int_metric(line, "maxChunksPerFrame") != 1
        ):
            fail(f"Mac remote tx used single-message sends for multi-chunk SBC2 frames: {line.strip()}")
        if line_wire_batch_single_frames + line_wire_batch_multi_frames + line_wire_single_unbatched_frames != line_sent_frames:
            fail(f"Mac remote tx send-mode evidence did not cover every sent frame: {line.strip()}")
        if metric(line, "writerClock") != "dispatch-source-userinteractive":
            fail(f"Mac remote tx did not use the strict DispatchSource writer clock: {line.strip()}")
        tx_writer_clock_ok += 1
        if metric(line, "sendScheduler") != "dispatch-clock-only":
            fail(f"Mac remote tx was not exclusively scheduled by the DispatchSource writer clock: {line.strip()}")
        tx_send_scheduler_ok += 1
        if int_metric(line, "chunkCapBytes") != 256 * 1024:
            fail(f"Mac remote SBC2 chunk cap did not match the LAN receive window: {line.strip()}")
        if int_metric(line, "dropped") != 0:
            fail(f"Mac remote dropped frames were nonzero: {line.strip()}")
        if line_backpressure != 0:
            fail(f"Mac remote harmful backpressure was nonzero: {line.strip()}")
        if line_queue_backlog != 0:
            fail(f"Mac remote queue backlog was nonzero: {line.strip()}")
        if int_metric(line, "contentBacklogLimit") != 12:
            fail(f"Mac remote contentBacklogLimit drifted from the strict 12-frame chunked contentProcessed pipeline: {line.strip()}")
        if int_metric(line, "contentBacklogByteLimit") != 12 * 256 * 1024:
            fail(f"Mac remote contentBacklogByteLimit drifted from the bounded chunked contentProcessed pipeline: {line.strip()}")
        if int_metric(line, "maxFramesPerDrain") != sender_cadence_catch_up_limit:
            fail(f"Mac remote maxFramesPerDrain was not the bounded strict cadence path: {line.strip()}")
        if int_metric(line, "scheduleBudgetMax") > sender_cadence_catch_up_limit:
            fail(f"Mac remote scheduleBudgetMax exceeded bounded strict cadence recovery: {line.strip()}")
        if int_metric(line, "missedCadenceSlotsMax") > bounded_missed_cadence_slots_limit:
            fail(f"Mac remote missed cadence slots exceeded strict zero-miss cadence window: {line.strip()}")
        if metric(line, "waitingForSync") != "false":
            fail(f"Mac remote was waiting for sync: {line.strip()}")

if sck_count == 0:
    fail("no Mac HEVC SCK telemetry samples inside final pass window")
if tx_count == 0:
    fail("no Mac remote frame tx telemetry samples inside final pass window")
if sck_count < minimum_window_samples:
    fail(f"too few Mac HEVC SCK telemetry samples inside final pass window: count={sck_count} required={minimum_window_samples}")
if tx_count < minimum_window_samples:
    fail(f"too few Mac remote frame tx telemetry samples inside final pass window: count={tx_count} required={minimum_window_samples}")
if tx_writer_clock_ok < tx_count:
    fail(f"Mac remote tx did not prove DispatchSource writer clock on every sample: ok={tx_writer_clock_ok} count={tx_count}")
if tx_send_scheduler_ok < tx_count:
    fail(f"Mac remote tx did not prove DispatchSource-only scheduling on every sample: ok={tx_send_scheduler_ok} count={tx_count}")
if sck_sample_ms <= 0:
    fail("Mac HEVC SCK telemetry did not report a positive aggregate sample window")
if tx_sample_ms <= 0:
    fail("Mac remote tx telemetry did not report a positive aggregate sample window")
if sck_cadence_timer_fires <= 0:
    fail("Mac HEVC SCK telemetry did not prove display cadence timer activity inside final pass window")
if sck_cadence_submitted <= 0:
    fail("Mac HEVC SCK telemetry did not prove display cadence frame submissions inside final pass window")
if sck_cadence_batch_max < 1:
    fail(f"Mac HEVC SCK display cadence batch max was invalid: cadenceBatchMax={sck_cadence_batch_max}")
if sck_cadence_batch_max > sck_cadence_catch_up_limit:
    fail(f"Mac HEVC SCK display cadence exceeded bounded producer recovery inside final pass window: cadenceBatchMax={sck_cadence_batch_max} limit={sck_cadence_catch_up_limit}")
sck_encoded_fps = sck_encoded_frames * 1000.0 / sck_sample_ms
sck_capture_fps = sck_captured_frames * 1000.0 / sck_sample_ms
sck_meaningful_fps = sck_meaningful_frames * 1000.0 / sck_sample_ms
tx_sent_fps = tx_sent_frames * 1000.0 / tx_sample_ms
if min_capture_fps is None or min_meaningful_fps is None:
    fail("Mac HEVC SCK telemetry did not expose captureFPS/meaningfulFPS inside final pass window")
if sck_source_frame_age_max_ms > max_sck_source_frame_age_ms:
    fail(f"Mac HEVC SCK source frame age exceeded live-source budget inside final pass window: sourceFrameAgeMaxMs={sck_source_frame_age_max_ms:.1f} budgetMs={max_sck_source_frame_age_ms:.1f}")
if sck_source_frame_repeat_max > max_sck_source_frame_repeat:
    fail(f"Mac HEVC SCK repeated stale source frames inside final pass window: sourceFrameRepeatMax={sck_source_frame_repeat_max} limit={max_sck_source_frame_repeat}")
if sck_encoded_fps < min_fps:
    fail(f"Mac HEVC aggregate encodedFPS below {min_fps}: encoded={sck_encoded_frames} sampleMs={sck_sample_ms} fps={sck_encoded_fps:.1f}")
if tx_sent_fps < min_fps:
    fail(f"Mac remote aggregate sentFPS below {min_fps}: sent={tx_sent_frames} sampleMs={tx_sample_ms} fps={tx_sent_fps:.1f}")
if tx_sent_fps > max_transport_fps:
    fail(f"Mac remote aggregate sentFPS exceeded strict target: sent={tx_sent_frames} sampleMs={tx_sample_ms} fps={tx_sent_fps:.1f} target={target_fps:.1f}")
if tx_max_sent_fps > max_transport_fps:
    fail(f"Mac remote burst sentFPS exceeded strict target: maxSentFPS={tx_max_sent_fps:.1f} target={target_fps:.1f}")
if tx_chunked_frames != tx_sent_frames:
    fail(f"Mac remote tx accepted non-SBC2 screen frames: sent={tx_sent_frames} chunkedFrames={tx_chunked_frames}")
if tx_wire_batch_single_frames + tx_wire_batch_multi_frames + tx_wire_single_unbatched_frames != tx_sent_frames:
    fail(
        "Mac remote tx did not prove an explicit Network.framework send mode for every final-window frame: "
        f"singleUnbatched={tx_wire_single_unbatched_frames} batchSingle={tx_wire_batch_single_frames} batchMulti={tx_wire_batch_multi_frames} sent={tx_sent_frames}"
    )
if tx_wire_batch_single_frames + tx_wire_batch_multi_frames + tx_wire_single_unbatched_frames <= 0:
    fail("Mac remote tx did not expose positive real send-mode evidence inside final pass window")
if tx_sent_chunks < tx_chunked_frames:
    fail(f"Mac remote tx reported fewer SBC2 chunks than frames: sentChunks={tx_sent_chunks} chunkedFrames={tx_chunked_frames}")
if tx_max_chunks_per_frame < 1:
    fail(f"Mac remote tx maxChunksPerFrame was invalid: maxChunksPerFrame={tx_max_chunks_per_frame}")
if tx_max_chunks_per_frame != 1:
    fail(f"Mac remote tx emitted multi-chunk HEVC frames inside final pass window: maxChunksPerFrame={tx_max_chunks_per_frame}")
if tx_queued_max > strict_mac_sender_queue_limit:
    fail(f"Mac remote queuedMax exceeded ordered SBC2 cadence buffer inside final pass window: queuedMax={tx_queued_max} limit={strict_mac_sender_queue_limit}")
if tx_content_backlog_limit != 12:
    fail(f"Mac remote contentBacklogLimit did not prove the strict 12-frame chunked contentProcessed pipeline: limit={tx_content_backlog_limit}")
if tx_content_backlog_byte_limit != 12 * 256 * 1024:
    fail(f"Mac remote contentBacklogByteLimit did not prove the bounded chunked contentProcessed pipeline: limit={tx_content_backlog_byte_limit}")
if tx_max_frames_per_drain != sender_cadence_catch_up_limit:
    fail(f"Mac remote maxFramesPerDrain did not prove bounded strict cadence recovery: maxFramesPerDrain={tx_max_frames_per_drain} expected={sender_cadence_catch_up_limit}")
if tx_schedule_budget_max > sender_cadence_catch_up_limit:
    fail(f"Mac remote scheduleBudgetMax exceeded bounded strict cadence recovery: scheduleBudgetMax={tx_schedule_budget_max} limit={sender_cadence_catch_up_limit}")
if tx_missed_cadence_slots_max > bounded_missed_cadence_slots_limit:
    fail(f"Mac remote missed cadence slots exceeded strict zero-miss cadence window inside final pass window: missedCadenceSlotsMax={tx_missed_cadence_slots_max} limit={bounded_missed_cadence_slots_limit}")
if tx_content_backlog_max > 12:
    fail(f"Mac remote contentProcessed backlog exceeded the strict 12-frame limit inside final pass window: contentBacklogMax={tx_content_backlog_max}")
if tx_content_backlog_max >= 12:
    fail(f"Mac remote contentProcessed backlog hit the strict 12-frame ceiling inside final pass window: contentBacklogMax={tx_content_backlog_max}")
if tx_content_backlog_bytes_max >= 12 * 256 * 1024:
    fail(f"Mac remote contentProcessed byte backlog hit the bounded ceiling inside final pass window: contentBacklogBytesMax={tx_content_backlog_bytes_max}")
if tx_content_backlog_full != 0:
    fail(f"Mac remote contentProcessed backlog hit the strict 12-frame/3072KiB ceiling inside final pass window: contentBacklogFull={tx_content_backlog_full}")
if tx_max_send_ms > 200.0:
    fail(f"Mac remote contentProcessed latency exceeded the 200ms budget inside final pass window: maxSendMs={tx_max_send_ms:.1f}")
max_bounded_schedule_gap_ms = 50.0
if tx_schedule_gap_max_ms > max_bounded_schedule_gap_ms:
    fail(f"Mac remote sender schedule gap exceeded 50ms inside final pass window: scheduleGapMaxMs={tx_schedule_gap_max_ms:.1f} budgetMs={max_bounded_schedule_gap_ms:.1f}")
if tx_schedule_jitter_max_ms > max_bounded_schedule_gap_ms:
    fail(f"Mac remote sender schedule jitter exceeded bounded recovery budget inside final pass window: scheduleJitterMaxMs={tx_schedule_jitter_max_ms:.1f} budgetMs={max_bounded_schedule_gap_ms:.1f}")
if tx_completion_gap_max_ms > 200.0:
    fail(f"Mac remote contentProcessed completion gap exceeded the 200ms budget inside final pass window: completionGapMaxMs={tx_completion_gap_max_ms:.1f}")
if tx_content_callback_gap_max_ms > 200.0:
    fail(f"Mac remote contentProcessed callback gap exceeded the 200ms budget inside final pass window: contentCallbackGapMaxMs={tx_content_callback_gap_max_ms:.1f}")
if tx_content_actor_hop_max_ms > 25.0:
    fail(f"Mac remote contentProcessed actor hop exceeded 25ms inside final pass window: contentActorHopMaxMs={tx_content_actor_hop_max_ms:.1f}")
if tx_clock_fire_to_drain_max_ms > 25.0:
    fail(f"Mac remote writer-clock fire to actor drain exceeded 25ms inside final pass window: clockFireToDrainMaxMs={tx_clock_fire_to_drain_max_ms:.1f}")
if tx_encoded_to_submit_max_ms > 100.0:
    fail(f"Mac remote encoded-to-sender actor delay exceeded 100ms inside final pass window: encodedToSubmitMaxMs={tx_encoded_to_submit_max_ms:.1f}")
if tx_submit_gap_max_ms > frame_budget_ms * 4.0:
    fail(f"Mac remote encoded-frame submit gap exceeded four-frame budget inside final pass window: submitGapMaxMs={tx_submit_gap_max_ms:.1f}")
if tx_oldest_content_backlog_ms > 300.0:
    fail(f"Mac remote oldest contentProcessed backlog exceeded 300ms inside final pass window: oldestContentBacklogMs={tx_oldest_content_backlog_ms:.1f}")
if tx_queue_age_max_ms > 100.0:
    fail(f"Mac remote queued frame age exceeded 100ms inside final pass window: queueAgeMaxMs={tx_queue_age_max_ms:.1f}")
if tx_dequeued_age_max_ms > 100.0:
    fail(f"Mac remote dequeued frame age exceeded 100ms inside final pass window: dequeuedAgeMaxMs={tx_dequeued_age_max_ms:.1f}")
if tx_stale_queue_catch_up != 0:
    fail(f"Mac remote stale queue catch-up was nonzero inside final pass window: staleQueueCatchUp={tx_stale_queue_catch_up}")
if audio_status_samples < minimum_window_samples:
    fail(f"iOS audio continuity telemetry had too few final-window samples: samples={audio_status_samples} required={minimum_window_samples}")
if audio_recv_start is None or audio_recv_end is None or audio_recv_end <= audio_recv_start:
    fail(f"iOS audio receive did not progress inside final pass window: recv={audio_recv_start}->{audio_recv_end}")
if audio_decoded_start is None or audio_decoded_end is None or audio_decoded_end <= audio_decoded_start:
    fail(f"iOS audio decode did not progress inside final pass window: decoded={audio_decoded_start}->{audio_decoded_end}")
if audio_played_start is None or audio_played_end is None or audio_played_end <= audio_played_start:
    fail(f"iOS audio playback did not progress inside final pass window: played={audio_played_start}->{audio_played_end}")

sck_source_callback_bottleneck = int(
    sck_capture_fps < min_fps
    or sck_meaningful_fps < min_fps
    or min_capture_fps < min_fps
    or min_meaningful_fps < min_fps
)

print(
    "remote performance window validation passed: "
    f"iosStatus={ios_status_count} metal={metal_count} macSCK={sck_count} macTx={tx_count} "
    f"iosWindowFPS={reported_window_fps:.1f} iosWindowRxFPS={reported_window_rx_fps:.1f} "
    f"metalDrawCallbackFPS={metal_draw_callback_fps:.1f} metalDisplayFPS={metal_displayed_fps:.1f} metalSubmittedFPS={metal_submitted_fps:.1f} "
    f"metalCoalesced={metal_coalesced_before_draw} metalCoalescedAllowed={max_allowed_metal_coalesced} metalRealtimeReplacement={metal_realtime_replacement_before_draw} metalManualDraw={metal_manual_draw} metalQueueCapacityMax={metal_queue_capacity_max} metalQueueDepthMax={metal_queue_depth_max} metalQueueBackpressure={metal_queue_backpressure} "
    f"metalFrameAgeMaxMs={metal_frame_age_max_ms:.1f} metalDisplayLinkPumpFPS={metal_display_link_pump_fps} "
    f"lanRxMaxGapMs={lan_rx_max_gap_ms:.1f} lanMaxScreenFPS={lan_rx_max_screen_fps:.1f} "
    f"audioSamples={audio_status_samples} audioRecv={audio_recv_start}->{audio_recv_end} audioDecoded={audio_decoded_start}->{audio_decoded_end} audioPlayed={audio_played_start}->{audio_played_end} "
    f"lanSourceSamples={lan_rx_source_samples} lanSourceGapMaxMs={lan_rx_source_gap_max_ms:.1f} "
    f"lanSourceToReadMaxMs={lan_rx_source_to_read_max_ms:.1f} lanSourceToReadUnsyncedClockSamples={lan_rx_source_to_read_unsynced_clock_samples}/{lan_rx_count} "
    f"lanSBC2Frames={lan_rx_sbc2_frames} lanSBC2Chunks={lan_rx_sbc2_chunks} "
    f"lanScreenDeliveryAttempted={lan_rx_screen_delivery_attempted} lanScreenDeliveryDelivered={lan_rx_screen_delivery_delivered} lanScreenDeliveryBackpressure={lan_rx_screen_delivery_backpressure} "
    f"lanRawChunks={lan_rx_raw_chunks} lanRawChunkGapMaxMs={lan_rx_raw_chunk_gap_max_ms:.1f} "
    f"lanRawChunkMainHopMaxMs={lan_rx_raw_chunk_main_hop_max_ms:.1f} lanReadAheadSamples={lan_rx_read_ahead_samples} "
    f"macCaptureFPS={sck_capture_fps:.1f} macMeaningfulFPS={sck_meaningful_fps:.1f} "
    f"macEncodedFPS={sck_encoded_fps:.1f} macSentFPS={tx_sent_fps:.1f} "
    f"macSourceFrameAgeMaxMs={sck_source_frame_age_max_ms:.1f} macSourceFrameRepeatMax={sck_source_frame_repeat_max} "
    f"macSCKSourceCallbackBottleneck={sck_source_callback_bottleneck} "
    f"macChunkedFrames={tx_chunked_frames} macSentChunks={tx_sent_chunks} macMaxChunksPerFrame={tx_max_chunks_per_frame} "
    f"macWireBatchSingleFrames={tx_wire_batch_single_frames} macWireBatchMultiFrames={tx_wire_batch_multi_frames} macWireSingleUnbatchedFrames={tx_wire_single_unbatched_frames} "
    f"macChunkCapBytes={tx_chunk_cap_bytes} macEncoderGOP={encoder_key_interval} macEncoderKeyDurationMs={encoder_key_duration_ms} "
    f"macEncoderLowLatencyRateControl={encoder_low_latency_rate_control} "
    f"macSCKCatchUpLimit={encoder_cadence_catch_up_limit} macEncoderBurstLimitBytes={encoder_burst_limit_bytes} "
    f"macSCKCadenceTimerFires={sck_cadence_timer_fires} macSCKCadenceSubmitted={sck_cadence_submitted} "
    f"macSCKCadenceCatchUpFrames={sck_cadence_catch_up_frames} macSCKCadenceBatchMax={sck_cadence_batch_max} "
    f"macEncoderBurstWindowMs={encoder_burst_window_ms} macEncoderDataRateLimitsStatus={encoder_data_rate_limits_status} "
    f"macEncoderDataRateLimitsReadbackStatus={encoder_data_rate_limits_readback_status} macEncoderDataRateLimitsApplied={encoder_data_rate_limits_applied} "
    f"macEncoderReadbackBurstLimitBytes={encoder_readback_burst_limit_bytes} macEncoderReadbackBurstWindowMs={encoder_readback_burst_window_ms} "
    f"macMaxFramesPerDrain={tx_max_frames_per_drain} "
    f"macScheduleBudgetMax={tx_schedule_budget_max} macMissedCadenceSlotsMax={tx_missed_cadence_slots_max} "
    f"macBackpressure={tx_backpressure} macRawBackpressure={tx_raw_backpressure} "
    f"macOrderedThrottle={tx_ordered_throttle} macQueueBacklog={tx_queue_backlog} "
    f"macQueuedMax={tx_queued_max} macInFlightMax={tx_inflight_max} "
    f"macContentBacklogMax={tx_content_backlog_max} macContentBacklogLimit={tx_content_backlog_limit} "
    f"macContentBacklogFull={tx_content_backlog_full} macOldestContentBacklogMs={tx_oldest_content_backlog_ms:.1f} "
    f"macQueueAgeMaxMs={tx_queue_age_max_ms:.1f} macDequeuedAgeMaxMs={tx_dequeued_age_max_ms:.1f} "
    f"macMaxSendMs={tx_max_send_ms:.1f} macMaxSentFPS={tx_max_sent_fps:.1f} "
    f"macScheduleGapMaxMs={tx_schedule_gap_max_ms:.1f} macScheduleJitterMaxMs={tx_schedule_jitter_max_ms:.1f} "
    f"macCompletionGapMaxMs={tx_completion_gap_max_ms:.1f} macContentCallbackGapMaxMs={tx_content_callback_gap_max_ms:.1f} "
    f"macContentActorHopMaxMs={tx_content_actor_hop_max_ms:.1f} "
    f"macClockFireToDrainMaxMs={tx_clock_fire_to_drain_max_ms:.1f} "
    f"macEncodedToSubmitMaxMs={tx_encoded_to_submit_max_ms:.1f} macSubmitGapMaxMs={tx_submit_gap_max_ms:.1f} "
    f"macStaleQueueCatchUp={tx_stale_queue_catch_up} "
    f"macCaptureMin={min_capture_fps:.1f} macMeaningfulMin={min_meaningful_fps:.1f}"
)
PY
}

launch_result_indicates_profile_trust_failure() {
  [[ -f "$LAUNCH_RESULT_JSON" ]] \
    && grep -qE 'invalid code signature|inadequate entitlements|profile has not been explicitly trusted' "$LAUNCH_RESULT_JSON"
}

launch_result_indicates_locked_device() {
  { [[ -f "$LAUNCH_RESULT_JSON" ]] && grep -qE 'Locked|could not be unlocked|device.*locked|Device.*locked|RequestDenied' "$LAUNCH_RESULT_JSON"; } \
    || { [[ -f "$IOS_CONSOLE_STDERR" ]] && grep -qE 'Locked|could not be unlocked|device.*locked|Device.*locked|RequestDenied' "$IOS_CONSOLE_STDERR"; }
}

report_ios_launch_failure() {
  local reason="$1"
  copy_ios_status
  echo "iOS remote smoke app launch failed before P2P handshake: ${reason}" >&2
  echo "This is a real-device launch/signing stage failure, not a P2P handshake or media pass." >&2
  echo "---- iOS launch result ($LAUNCH_RESULT_JSON) ----" >&2
  cat "$LAUNCH_RESULT_JSON" >&2 2>/dev/null || true
  echo "---- iOS console stderr ($IOS_CONSOLE_STDERR) ----" >&2
  tail -n 80 "$IOS_CONSOLE_STDERR" >&2 2>/dev/null || true
  echo "---- iOS status tail ($IOS_STATUS_LOCAL) ----" >&2
  tail -n 80 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
}

launch_ios_remote_smoke_app() {
  local started_at
  local attempt=1
  started_at="$(date +%s)"
  while true; do
    rm -f "$LAUNCH_RESULT_JSON" "$IOS_STATUS_LOCAL" "$IOS_STATUS_APP_CACHE_LOCAL" "$IOS_STATUS_CONSOLE_SNAPSHOT" "$IOS_CONSOLE_STDERR"
    xcrun devicectl device process launch \
      --device "$IOS_DEVICE_ID" \
      --terminate-existing \
      --console \
      --timeout "$IOS_LAUNCH_TIMEOUT_SECONDS" \
      --environment-variables "$IOS_ENV_JSON" \
      --json-output "$LAUNCH_RESULT_JSON" \
      "$IOS_BUNDLE_ID" >"$IOS_STATUS_LOCAL" 2>"$IOS_CONSOLE_STDERR" &
    IOS_CONSOLE_PID="$!"

    local attempt_started_at
    attempt_started_at="$(date +%s)"
    while true; do
      if launch_result_indicates_profile_trust_failure; then
        report_ios_launch_failure "code signature/profile/trust rejected by device"
        return 1
      fi
      if launch_result_indicates_locked_device; then
        if kill -0 "$IOS_CONSOLE_PID" >/dev/null 2>&1; then
          kill "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
        fi
        wait "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
        IOS_CONSOLE_PID=""
        if (( "$(date +%s)" - started_at >= IOS_LAUNCH_TIMEOUT_SECONDS )); then
          report_ios_launch_failure "device remained locked for ${IOS_LAUNCH_TIMEOUT_SECONDS}s"
          echo "Unlock the iPad/iPhone and rerun; this is a real-device precondition, not a remote desktop media pass." >&2
          return 1
        fi
        echo "    iOS remote launch attempt ${attempt} was denied because the device is locked; unlock the device, keep it awake, and waiting..." >&2
        attempt=$((attempt + 1))
        sleep 5
        break
      fi
      if [[ -f "$LAUNCH_RESULT_JSON" ]] && grep -qE '"outcome"[[:space:]]*:[[:space:]]*"failed"|CoreDeviceError|FBSOpenApplication' "$LAUNCH_RESULT_JSON"; then
        report_ios_launch_failure "devicectl launch failed"
        return 1
      fi
      if ! kill -0 "$IOS_CONSOLE_PID" >/dev/null 2>&1; then
        wait "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
        if [[ -f "$LAUNCH_RESULT_JSON" ]] && grep -qE '"outcome"[[:space:]]*:[[:space:]]*"failed"|CoreDeviceError|FBSOpenApplication' "$LAUNCH_RESULT_JSON"; then
          report_ios_launch_failure "devicectl launch process exited with failure"
          return 1
        fi
        return 0
      fi
      if (( "$(date +%s)" - attempt_started_at >= 8 )); then
        return 0
      fi
      sleep 1
    done
  done
}

echo "==> Artifacts: $ARTIFACT_DIR"
echo "==> Real device: $IOS_DEVICE_ID"
echo "==> Build destination: $IOS_BUILD_DESTINATION"
echo "==> Target: ${SMOKE_VIDEO_WIDTH}x${SMOKE_VIDEO_HEIGHT}@${SMOKE_TARGET_FPS} minFps=${SMOKE_MIN_FPS}"
echo "==> Expected render orientation: $SMOKE_EXPECT_RENDER_ORIENTATION"
echo "==> Expected suite: $EXPECTED_TARGET_SUITE"

xcrun devicectl list devices >"$DEVICE_INFO_TXT" 2>&1 || true

echo "==> Building macOS LAN host"
(
  cd "$ROOT_DIR"
  SWIFTPM_CACHE_PATH="$SWIFTPM_CACHE_DIR" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
  swift build --product LocalLanInteropHost
) >"$ARTIFACT_DIR/macos-build.log"

MAC_APP_BIN="$ROOT_DIR/.build/debug/LocalLanInteropHost"
if [[ ! -x "$MAC_APP_BIN" ]]; then
  echo "macOS LAN host executable not found: $MAC_APP_BIN" >&2
  exit 1
fi

echo "==> Starting macOS LAN host"
SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
SB_PQC_PREFERRED_SUITE="$HOST_PREFERRED_SUITE" \
SKYBRIDGE_SMOKE_ROLE=mac-host \
SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING="$SMOKE_AUTO_APPROVE_PAIRING" \
SKYBRIDGE_SMOKE_STATUS_FILE="$HOST_STATUS" \
SKYBRIDGE_SMOKE_PQC_REPORT_FILE="$HOST_PQC_REPORT" \
SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE="$EXPECTED_TARGET_SUITE" \
SKYBRIDGE_SMOKE_REMOTE_ANIMATION=1 \
"$MAC_APP_BIN" >"$HOST_STDOUT" 2>&1 &
HOST_PID="$!"

wait_for_file_pattern "$HOST_STATUS" 'ready discovery=_skybridge._tcp' 60 "macOS host ready"
wait_for_file_pattern "$HOST_STATUS" 'smoke-capture-source active=1' 60 "macOS smoke capture source"
verify_mac_smoke_capture_source_visible
wait_for_file_pattern "$HOST_PQC_REPORT" '"deviceId"' 60 "macOS PQC report"

REPORT_DATA="$(python3 - "$HOST_PQC_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
keys = {
    int(entry.get("suiteWireId", -1)): entry.get("publicKeyBase64", "")
    for entry in report.get("keys", [])
}
print(report.get("deviceId", ""))
print(keys.get(0x0001, ""))
print(keys.get(0x0101, ""))
print(keys.get(0x0102, ""))
PY
)"

MAC_PQC_DEVICE_ID="$(printf '%s\n' "$REPORT_DATA" | sed -n '1p')"
MAC_PQC_XWING_PUBLIC_KEY_BASE64="$(printf '%s\n' "$REPORT_DATA" | sed -n '2p')"
MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64="$(printf '%s\n' "$REPORT_DATA" | sed -n '3p')"
MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64="$(printf '%s\n' "$REPORT_DATA" | sed -n '4p')"

if [[ -z "$MAC_PQC_DEVICE_ID" || -z "$MAC_PQC_XWING_PUBLIC_KEY_BASE64" ]]; then
  echo "PQC report is missing required X-Wing identity: $HOST_PQC_REPORT" >&2
  exit 1
fi

echo "==> Building iOS app for real device"
xcodebuild \
  -project "$IOS_PROJECT" \
  -scheme "$IOS_SCHEME" \
  -configuration Debug \
  -destination "$IOS_BUILD_DESTINATION" \
  -derivedDataPath "$ARTIFACT_DIR/DerivedData-ios" \
  build >"$IOS_BUILD_LOG"

IOS_APP_PATH="$ARTIFACT_DIR/DerivedData-ios/Build/Products/Debug-iphoneos/SkyBridgeCompass-iOS.app"
if [[ ! -d "$IOS_APP_PATH" ]]; then
  echo "iOS app bundle not found: $IOS_APP_PATH" >&2
  exit 1
fi

echo "==> Installing iOS app on real device"
if [[ "$PRESERVE_INSTALL" != "1" ]]; then
  xcrun devicectl device uninstall app --device "$IOS_DEVICE_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
else
  echo "    preserving existing install to keep Local Network/TCC grants when possible"
fi
xcrun devicectl device install app --device "$IOS_DEVICE_ID" "$IOS_APP_PATH" >/dev/null

echo "==> Launching iOS P2P remote smoke"
IOS_PQC_PEER_DEVICE_ID=""
IOS_PQC_PEER_XWING_PUBLIC_KEY_BASE64=""
IOS_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64=""
IOS_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64=""
if [[ "$PQC_TRUST_MODE" == "injected" ]]; then
  IOS_PQC_PEER_DEVICE_ID="$MAC_PQC_DEVICE_ID"
  IOS_PQC_PEER_XWING_PUBLIC_KEY_BASE64="$MAC_PQC_XWING_PUBLIC_KEY_BASE64"
  IOS_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64"
  IOS_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64"
  echo "    trust mode: injected KEM public keys (diagnostic only)"
else
  echo "    trust mode: user app trust store (no injected KEM keys)"
fi
IOS_ENV_JSON="$(
  SKYBRIDGE_SMOKE_TARGET_DEVICE_ID="$MAC_PQC_DEVICE_ID" \
  SKYBRIDGE_SMOKE_TARGET_NAME="$MAC_TARGET_NAME" \
  SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
  SKYBRIDGE_SMOKE_REMOTE_DESKTOP_TIMEOUT_SECONDS="$SMOKE_REMOTE_TIMEOUT_SECONDS" \
  SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_NAME" \
  SKYBRIDGE_SMOKE_MIN_FPS="$SMOKE_MIN_FPS" \
  SKYBRIDGE_SMOKE_TARGET_FPS="$SMOKE_TARGET_FPS" \
  SKYBRIDGE_SMOKE_SOAK_SECONDS="$SMOKE_SOAK_SECONDS" \
  SKYBRIDGE_SMOKE_VIDEO_WIDTH="$SMOKE_VIDEO_WIDTH" \
  SKYBRIDGE_SMOKE_VIDEO_HEIGHT="$SMOKE_VIDEO_HEIGHT" \
  SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION="$SMOKE_EXPECT_RENDER_ORIENTATION" \
  SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH="$SMOKE_REQUIRE_SIGNED_KEM_REFRESH" \
  SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH="$SMOKE_FORCE_SIGNED_KEM_REFRESH" \
  SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING="$SMOKE_AUTO_APPROVE_PAIRING" \
  SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE="$EXPECTED_TARGET_SUITE" \
  SB_PQC_PREFERRED_SUITE="$IOS_PREFERRED_SUITE" \
  SKYBRIDGE_PQC_PEER_DEVICE_ID="$IOS_PQC_PEER_DEVICE_ID" \
  SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64="$IOS_PQC_PEER_XWING_PUBLIC_KEY_BASE64" \
  SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64="$IOS_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64" \
  SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64="$IOS_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64" \
  python3 - <<'PY'
import json
import os

keys = [
    "SKYBRIDGE_SMOKE_TARGET_DEVICE_ID",
    "SKYBRIDGE_SMOKE_TARGET_NAME",
    "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS",
    "SKYBRIDGE_SMOKE_REMOTE_DESKTOP_TIMEOUT_SECONDS",
    "SKYBRIDGE_SMOKE_STATUS_BASENAME",
    "SKYBRIDGE_SMOKE_MIN_FPS",
    "SKYBRIDGE_SMOKE_TARGET_FPS",
    "SKYBRIDGE_SMOKE_SOAK_SECONDS",
    "SKYBRIDGE_SMOKE_VIDEO_WIDTH",
    "SKYBRIDGE_SMOKE_VIDEO_HEIGHT",
    "SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION",
    "SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH",
    "SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH",
    "SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING",
    "SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE",
    "SB_PQC_PREFERRED_SUITE",
    "SKYBRIDGE_PQC_PEER_DEVICE_ID",
    "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64",
]
env = {
    "SKYBRIDGE_KEYCHAIN_IN_MEMORY": "1",
    "SKYBRIDGE_SMOKE_ROLE": "ios-p2p-client",
    "SKYBRIDGE_SMOKE_EXPECT_REMOTE_DESKTOP": "1",
    "SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB": "1",
    "SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW": "1",
    "SKYBRIDGE_SMOKE_REQUIRE_AUDIO": "1",
    "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY": "0",
    "SKYBRIDGE_SMOKE_EXTREME_MEDIA": "1",
    "SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK": "1",
}
for key in keys:
    value = os.environ.get(key)
    if value:
        env[key] = value
print(json.dumps(env, ensure_ascii=False))
PY
)"

launch_ios_remote_smoke_app

echo "==> Waiting for P2P handshake"
wait_for_file_pattern "$HOST_STATUS" "$HOST_HANDSHAKE_PATTERN" "$SMOKE_TIMEOUT_SECONDS" "macOS P2P handshake"
if [[ "$SMOKE_REQUIRE_SIGNED_KEM_REFRESH" == "1" ]]; then
  echo "==> Waiting for PIB-1 protocol identity binding evidence"
  wait_for_ios_status_pattern 'PIB-1 protocol identity binding request: .*lifecycle=identity-oob>request' "$SMOKE_TIMEOUT_SECONDS" "iOS PIB-1 request"
  wait_for_file_pattern "$HOST_STATUS" 'PIB-1 protocol identity binding served: .*lifecycle=identity-oob>served' "$SMOKE_TIMEOUT_SECONDS" "macOS PIB-1 served"
  wait_for_ios_status_pattern 'PIB-1 protocol identity binding signature verified: .*lifecycle=identity-oob>verified' "$SMOKE_TIMEOUT_SECONDS" "iOS PIB-1 verified"
  wait_for_ios_status_pattern 'PIB-1 protocol identity binding pinned: .*lifecycle=identity-oob>pinned' "$SMOKE_TIMEOUT_SECONDS" "iOS PIB-1 pinned"
  echo "==> Waiting for SKR-1 signed KEM refresh evidence"
  wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh request: .*lifecycle=missing-kem>request' "$SMOKE_TIMEOUT_SECONDS" "iOS SKR-1 request"
  wait_for_file_pattern "$HOST_STATUS" 'SKR-1 signed LAN KEM refresh served: .*lifecycle=request>served' "$SMOKE_TIMEOUT_SECONDS" "macOS SKR-1 served"
  wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh verified and imported: .*signature=verified .*requestHash=bound .*lifecycle=served>verified' "$SMOKE_TIMEOUT_SECONDS" "iOS SKR-1 verified import"
  wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh smoke-evidence: .*source=signed_lan_kem_refresh .*signature=verified .*requestHash=bound .*strictXWingEstablished=1' "$SMOKE_TIMEOUT_SECONDS" "iOS SKR-1 smoke evidence"
fi
wait_for_ios_status_pattern "streamConfigSent .*preferred=hevc, formats=hevc, fps=${SMOKE_TARGET_FPS}.*perf=extreme" "$SMOKE_TIMEOUT_SECONDS" "strict HEVC-only stream configuration"
wait_for_ios_status_pattern "success .*suite=${EXPECTED_TARGET_SUITE} .*handshakeOnly=1 .*remoteDesktop=1" "$SMOKE_TIMEOUT_SECONDS" "iOS P2P remote desktop success"
wait_for_ios_status_pattern "remote-desktop-pass .*renderOrientation=${SMOKE_EXPECT_RENDER_ORIENTATION}" "$SMOKE_TIMEOUT_SECONDS" "P2P remote desktop pass window"
copy_ios_status
validate_remote_desktop_route_evidence
validate_remote_desktop_performance_window
append_host_status "smoke-final result=success validated=1 route=lan-main fps=${SMOKE_MIN_FPS} frame=${SMOKE_VIDEO_WIDTH}x${SMOKE_VIDEO_HEIGHT}"
append_ios_status "smoke-final result=success validated=1 route=lan-main fps=${SMOKE_MIN_FPS} frame=${SMOKE_VIDEO_WIDTH}x${SMOKE_VIDEO_HEIGHT}"

echo "==> Real-device P2P remote desktop smoke succeeded"
echo "    mac status: $HOST_STATUS"
echo "    ios status: $IOS_STATUS_LOCAL"
echo "    host stdout: $HOST_STDOUT"
