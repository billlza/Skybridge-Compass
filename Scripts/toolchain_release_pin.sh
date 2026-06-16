#!/usr/bin/env bash
# shellcheck disable=SC2034  # SKYBRIDGE_PIN_* are set here and read by sourcing scripts (cross-file).
# Single source of truth for the SkyBridge macOS release toolchain pin.
#
# WHY THIS FILE EXISTS
#   The Xcode/Swift/SDK version that a release is allowed to be built with used
#   to be duplicated (by exact string) across verify_xcode_toolchain.sh,
#   package_build_policy.sh, publish_macos_update_release.sh and the CI
#   workflow. Bumping the toolchain meant editing every copy in lockstep, which
#   does not scale across an OS-version transition. This file centralizes the
#   pin so a future bump (or the OS 27 cutover) is a single, reviewable edit.
#
# OLD-DEVICE COMPATIBILITY IS NOT DEFINED HERE — ON PURPOSE
#   The runtime deployment FLOORS (LSMinimumSystemVersion 14.0, the SwiftPM
#   .macOS(.v14)/.iOS(.v17) targets, IPHONEOS_DEPLOYMENT_TARGET 17.0) are
#   INDEPENDENT of the build SDK and must never move when the build toolchain is
#   bumped. They are asserted as hard, exact floors by the callers regardless of
#   which line below is selected. Building with the macOS 27 SDK does not — and
#   must not — drop support for macOS 14/15 or iOS 17.
#
# LINE SELECTION
#   SKYBRIDGE_RELEASE_TOOLCHAIN_LINE selects the line. Default "xcode26" keeps
#   the established stable behavior (and every existing test) unchanged. Set it
#   to "xcode27" to verify/build an Xcode 27 (OS 27) release.

SKYBRIDGE_RELEASE_TOOLCHAIN_LINE="${SKYBRIDGE_RELEASE_TOOLCHAIN_LINE:-xcode26}"

# skybridge_release_pin_load [line]
#   Populates the SKYBRIDGE_PIN_* variables for the requested line. Returns 64
#   for an unknown line.
skybridge_release_pin_load() {
  local line="${1:-${SKYBRIDGE_RELEASE_TOOLCHAIN_LINE:-xcode26}}"
  case "${line}" in
    xcode26)
      # Stable shipping line. Exact-match everything (good supply-chain hygiene).
      SKYBRIDGE_PIN_LINE="xcode26"
      SKYBRIDGE_PIN_XCODE_VERSION="26.5"
      SKYBRIDGE_PIN_XCODE_BUILD="17F42"
      SKYBRIDGE_PIN_SWIFT_VERSION="6.3.2"
      SKYBRIDGE_PIN_MACOS_SDK_VERSION="26.5"
      SKYBRIDGE_PIN_DT_SDK_NAME="macosx26.5"
      SKYBRIDGE_PIN_DT_XCODE="2650"
      SKYBRIDGE_PIN_DT_XCODE_BUILD="17F42"
      SKYBRIDGE_PIN_SWIFT_TARGET="arm64-apple-macosx26.0"
      SKYBRIDGE_PIN_MATCH_MODE="exact"
      SKYBRIDGE_PIN_ALLOW_BETA="0"
      SKYBRIDGE_PIN_VERIFY_POLICY="stable-release"
      ;;
    xcode27)
      # OS 27 line. Major-tolerant within the 27 series so 27.x point releases
      # and rotating beta build ids do NOT require re-pinning (this is what keeps
      # release maintenance feasible across the 27 cycle). Beta developer dirs
      # are allowed while Xcode 27 ships as beta; flip SKYBRIDGE_PIN_XCODE27_ALLOW_BETA
      # to 0 once Xcode 27 GA is on the build machine.
      SKYBRIDGE_PIN_LINE="xcode27"
      SKYBRIDGE_PIN_XCODE_VERSION="${SKYBRIDGE_PIN_XCODE27_VERSION:-27}"
      SKYBRIDGE_PIN_XCODE_BUILD=""
      SKYBRIDGE_PIN_SWIFT_VERSION="${SKYBRIDGE_PIN_XCODE27_SWIFT:-6.4}"
      SKYBRIDGE_PIN_MACOS_SDK_VERSION="27"
      SKYBRIDGE_PIN_DT_SDK_NAME="macosx27"
      SKYBRIDGE_PIN_DT_XCODE="27"
      SKYBRIDGE_PIN_DT_XCODE_BUILD=""
      SKYBRIDGE_PIN_SWIFT_TARGET="arm64-apple-macosx27.0"
      SKYBRIDGE_PIN_MATCH_MODE="major"
      SKYBRIDGE_PIN_ALLOW_BETA="${SKYBRIDGE_PIN_XCODE27_ALLOW_BETA:-1}"
      SKYBRIDGE_PIN_VERIFY_POLICY="os27-release"
      ;;
    *)
      echo "[toolchain-release-pin] ERROR: unknown release toolchain line: ${line}" >&2
      return 64
      ;;
  esac
  return 0
}

# skybridge_release_pin_match_version <expected> <actual> <mode>
#   exact: string equality. major: compare leading major component only
#   (expected may be "27" or "27.0"; actual "27.3" matches).
skybridge_release_pin_match_version() {
  local expected="$1" actual="$2" mode="${3:-exact}"
  [[ -n "${actual}" ]] || return 1
  if [[ "${mode}" == "exact" ]]; then
    [[ "${actual}" == "${expected}" ]]
    return $?
  fi
  local emaj="${expected%%.*}" amaj="${actual%%.*}"
  [[ -n "${emaj}" && "${amaj}" == "${emaj}" ]]
}

# skybridge_release_pin_match_prefix <expected> <actual> <mode>
#   exact: string equality. major: actual must start with expected
#   (e.g. expected "macosx27" matches actual "macosx27.0"/"macosx27.3").
skybridge_release_pin_match_prefix() {
  local expected="$1" actual="$2" mode="${3:-exact}"
  [[ -n "${actual}" ]] || return 1
  if [[ "${mode}" == "exact" ]]; then
    [[ "${actual}" == "${expected}" ]]
    return $?
  fi
  [[ "${actual}" == "${expected}"* ]]
}

# skybridge_release_pin_verify_policy [line]
#   Echoes the verify_xcode_toolchain.sh policy name for the line.
skybridge_release_pin_verify_policy() {
  local line="${1:-${SKYBRIDGE_RELEASE_TOOLCHAIN_LINE:-xcode26}}"
  case "${line}" in
    xcode26) printf 'stable-release\n' ;;
    xcode27) printf 'os27-release\n' ;;
    *) printf 'stable-release\n' ;;
  esac
}
