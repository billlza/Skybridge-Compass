#!/usr/bin/env bash

# Bind one physical-device evidence directory to the exact signed candidate.
# SHA-256 in the candidate document detects accidental cross-run mismatch;
# codesign, notarization, and Gatekeeper are validated by the identity tool.

skybridge_bind_macos_release_candidate_evidence() {
  if (( $# != 4 )); then
    echo "skybridge_bind_macos_release_candidate_evidence requires project root, expected app, artifact dir, and lab flag" >&2
    return 2
  fi
  local project_root="$1"
  local expected_app="$2"
  local artifact_dir="$3"
  local lab_run="$4"
  local identity="${SKYBRIDGE_RELEASE_CANDIDATE_MANIFEST:-}"
  local candidate_app="${SKYBRIDGE_RELEASE_CANDIDATE_APP_PATH:-}"
  local candidate_dmg="${SKYBRIDGE_RELEASE_CANDIDATE_DMG_PATH:-}"
  local destination="${artifact_dir}/macos-release-candidate.json"
  local expected_app_real=""
  local candidate_app_real=""

  case "$lab_run" in
    0|1) ;;
    *)
      echo "release candidate evidence binding requires a 0/1 lab flag" >&2
      return 2
      ;;
  esac

  if [[ -z "$identity" && -z "$candidate_app" && -z "$candidate_dmg" ]]; then
    if [[ "$lab_run" == "1" ]]; then
      return 0
    fi
    echo "formal evidence requires SKYBRIDGE_RELEASE_CANDIDATE_MANIFEST, SKYBRIDGE_RELEASE_CANDIDATE_APP_PATH, and SKYBRIDGE_RELEASE_CANDIDATE_DMG_PATH" >&2
    return 1
  fi
  if [[ -z "$identity" || -z "$candidate_app" || -z "$candidate_dmg" ]]; then
    echo "release candidate evidence binding inputs must be supplied together" >&2
    return 1
  fi
  if [[ "$identity" != /* || "$candidate_app" != /* || "$candidate_dmg" != /* ]]; then
    echo "release candidate evidence binding inputs must be absolute paths" >&2
    return 1
  fi
  if [[ ! -f "$identity" || -L "$identity" || ! -d "$candidate_app" || -L "$candidate_app" || ! -f "$candidate_dmg" || -L "$candidate_dmg" ]]; then
    echo "release candidate evidence binding inputs must be real files/directories" >&2
    return 1
  fi
  if [[ ! -d "$expected_app" || -L "$expected_app" || ! -d "$artifact_dir" || -L "$artifact_dir" ]]; then
    echo "release candidate evidence binding expected app/artifact directory is invalid" >&2
    return 1
  fi
  expected_app_real="$(cd "$expected_app" && pwd -P)" || return 1
  candidate_app_real="$(cd "$candidate_app" && pwd -P)" || return 1
  if [[ "$expected_app_real" != "$candidate_app_real" ]]; then
    echo "the physical producer is not configured to run the immutable candidate app" >&2
    return 1
  fi
  python3 "$project_root/Scripts/macos_release_candidate_identity.py" verify \
    --identity "$identity" \
    --app "$candidate_app" \
    --dmg "$candidate_dmg" || return 1
  if [[ -e "$destination" || -L "$destination" ]]; then
    echo "release evidence candidate identity destination already exists" >&2
    return 1
  fi
  /bin/cp -p "$identity" "$destination" || return 1
  chmod 0600 "$destination" || return 1
}

skybridge_verify_public_macos_release_candidate_evidence() {
  if (( $# != 3 )); then
    echo "skybridge_verify_public_macos_release_candidate_evidence requires project root, private dir, and public dir" >&2
    return 2
  fi
  local project_root="$1"
  local private_dir="$2"
  local public_dir="$3"
  local private_identity="${private_dir}/macos-release-candidate.json"
  local public_identity="${public_dir}/macos-release-candidate.json"
  if [[ ! -f "$private_identity" ]]; then
    return 0
  fi
  python3 "$project_root/Scripts/macos_release_candidate_identity.py" compare \
    --expected "$private_identity" \
    --actual "$public_identity"
}
