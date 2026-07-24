#!/usr/bin/env bash

# Shared iOS App + Widget distribution signing proof used by every physical release lane.
# The caller must source signing_entitlements_helpers.sh first.

skybridge_write_ios_distribution_product_proof() {
  if (( $# != 18 )); then
    echo "skybridge_write_ios_distribution_product_proof requires 18 arguments" >&2
    return 2
  fi

  local app_path="$1"
  local widget_path="$2"
  local app_profile="$3"
  local widget_profile="$4"
  local expected_entitlements="$5"
  local output_path="$6"
  local proof_dir="$7"
  local app_bundle_identifier="$8"
  local widget_bundle_identifier="$9"
  local expected_team="${10}"
  local configuration="${11}"
  local lab_run="${12}"
  local source_revision="${13}"
  local source_clean="${14}"
  local device_identifier="${15}"
  local selected_app_profile="${16}"
  local selected_widget_profile="${17}"
  local verifier_path="${18}"

  local app_signed_entitlements="$proof_dir/app-signed-entitlements.plist"
  local widget_signed_entitlements="$proof_dir/widget-signed-entitlements.plist"
  local app_certificate_prefix="$proof_dir/app-signing-certificate-"
  local widget_certificate_prefix="$proof_dir/widget-signing-certificate-"
  local app_leaf_certificate="${app_certificate_prefix}0"
  local widget_leaf_certificate="${widget_certificate_prefix}0"
  local app_signing_metadata
  local widget_signing_metadata
  local app_signed_identifier
  local widget_signed_identifier
  local app_signed_team_identifier
  local widget_signed_team_identifier
  local app_signing_authority
  local widget_signing_authority
  local app_signing_authority_class
  local widget_signing_authority_class
  local product_build_configuration
  local product_dirty_state
  local product_source_revision
  local product_source_repository
  local product_surface
  local product_swift_conditions
  local expected_source_repository
  local app_executable_name
  local app_executable_path
  local binary_strings_path
  local binary_test_surface_detected=0
  local expected_dirty_state
  local product_provenance_verified=0

  for required_path in \
    "$app_path" \
    "$widget_path" \
    "$app_profile" \
    "$widget_profile" \
    "$expected_entitlements" \
    "$verifier_path"; do
    if [[ ! -e "$required_path" || -L "$required_path" ]]; then
      echo "Required iOS distribution proof input is missing or symlinked: $required_path" >&2
      return 1
    fi
  done
  if [[ ! "$source_clean" =~ ^[01]$ || ! "$lab_run" =~ ^[01]$ ]]; then
    echo "Invalid iOS distribution proof mode/provenance input." >&2
    return 2
  fi

  product_build_configuration="$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingBuildConfiguration' "$app_path/Info.plist" 2>/dev/null || true)"
  product_dirty_state="$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingGitDirtyState' "$app_path/Info.plist" 2>/dev/null || true)"
  product_source_revision="$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingGitCommit' "$app_path/Info.plist" 2>/dev/null || true)"
  product_source_repository="$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingSourceRepository' "$app_path/Info.plist" 2>/dev/null || true)"
  product_surface="$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingProductSurface' "$app_path/Info.plist" 2>/dev/null || true)"
  product_swift_conditions="$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingSwiftActiveCompilationConditions' "$app_path/Info.plist" 2>/dev/null || true)"
  expected_source_repository="${GITHUB_REPOSITORY:-${SKYBRIDGE_SOURCE_REPOSITORY:-}}"
  if [[ "$source_clean" == "1" ]]; then
    expected_dirty_state="clean"
  else
    expected_dirty_state="dirty"
  fi
  if [[ "$product_build_configuration" == "$configuration" && \
        "$product_dirty_state" == "$expected_dirty_state" && \
        "$product_source_revision" == "$source_revision" && \
        -n "$expected_source_repository" && \
        "$product_source_repository" == "$expected_source_repository" ]]; then
    product_provenance_verified=1
  fi

  mkdir -p "$proof_dir"
  chmod 0700 "$proof_dir"
  app_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Info.plist" 2>/dev/null || true)"
  app_executable_path="$app_path/$app_executable_name"
  if [[ -z "$app_executable_name" || ! -f "$app_executable_path" || -L "$app_executable_path" ]]; then
    echo "The signed iOS app executable is missing or linked." >&2
    return 1
  fi
  binary_strings_path="$proof_dir/app-binary-strings.txt"
  if ! /usr/bin/strings -a "$app_executable_path" >"$binary_strings_path"; then
    echo "Unable to scan the signed iOS app executable for test-only surfaces." >&2
    return 1
  fi
  if LC_ALL=C grep -Eq \
    'SKYBRIDGE_TESTING|SKYBRIDGE_SMOKE_[A-Za-z0-9_]*|[A-Za-z0-9_]*(SmokeHarness|SmokeStatusWriter|SmokeStatusReporter|SmokeStreamOverrides|SmokeTraceWriter)' \
    "$binary_strings_path"; then
    binary_test_surface_detected=1
  fi
  rm -f -- "$binary_strings_path"
  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null; then
    echo "The iOS product failed strict nested code-signature verification." >&2
    return 1
  fi
  if ! /usr/bin/codesign --verify --strict --verbose=2 "$widget_path" >/dev/null; then
    echo "The embedded iOS Widget failed strict code-signature verification." >&2
    return 1
  fi
  if ! app_signing_metadata="$(/usr/bin/codesign --display --verbose=4 "$app_path" 2>&1)" || \
     ! widget_signing_metadata="$(/usr/bin/codesign --display --verbose=4 "$widget_path" 2>&1)"; then
    echo "Unable to read the iOS app and Widget signature metadata." >&2
    return 1
  fi

  app_signed_identifier="$(printf '%s\n' "$app_signing_metadata" | sed -n 's/^Identifier=//p' | head -n 1)"
  widget_signed_identifier="$(printf '%s\n' "$widget_signing_metadata" | sed -n 's/^Identifier=//p' | head -n 1)"
  app_signed_team_identifier="$(printf '%s\n' "$app_signing_metadata" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  widget_signed_team_identifier="$(printf '%s\n' "$widget_signing_metadata" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  app_signing_authority="$(printf '%s\n' "$app_signing_metadata" | sed -n 's/^Authority=//p' | head -n 1)"
  widget_signing_authority="$(printf '%s\n' "$widget_signing_metadata" | sed -n 's/^Authority=//p' | head -n 1)"
  if [[ "$app_signed_identifier" != "$app_bundle_identifier" || \
        "$widget_signed_identifier" != "$widget_bundle_identifier" || \
        "$app_signed_team_identifier" != "$expected_team" || \
        "$widget_signed_team_identifier" != "$expected_team" ]]; then
    echo "The iOS app and Widget signed bundle/team identities are invalid." >&2
    return 1
  fi
  case "$app_signing_authority" in
    Apple\ Distribution:*|iPhone\ Distribution:*) app_signing_authority_class="apple-distribution" ;;
    Apple\ Development:*|iPhone\ Developer:*) app_signing_authority_class="apple-development" ;;
    *)
      echo "The iOS app is not signed by an accepted Apple authority." >&2
      return 1
      ;;
  esac
  case "$widget_signing_authority" in
    Apple\ Distribution:*|iPhone\ Distribution:*) widget_signing_authority_class="apple-distribution" ;;
    Apple\ Development:*|iPhone\ Developer:*) widget_signing_authority_class="apple-development" ;;
    *)
      echo "The iOS Widget is not signed by an accepted Apple authority." >&2
      return 1
      ;;
  esac

  rm -f -- "${app_certificate_prefix}"* "${widget_certificate_prefix}"*
  if ! /usr/bin/codesign --display --extract-certificates "$app_certificate_prefix" "$app_path" >/dev/null 2>&1 || \
     [[ ! -s "$app_leaf_certificate" ]] || \
     ! /usr/bin/codesign --display --extract-certificates "$widget_certificate_prefix" "$widget_path" >/dev/null 2>&1 || \
     [[ ! -s "$widget_leaf_certificate" ]]; then
    echo "Unable to extract the iOS app and Widget leaf signing certificates." >&2
    return 1
  fi
  if ! skybridge_write_signed_entitlements "$app_path" "$app_signed_entitlements" || \
     ! skybridge_write_signed_entitlements "$widget_path" "$widget_signed_entitlements"; then
    echo "Unable to extract signed entitlements from the iOS app and Widget." >&2
    return 1
  fi
  if ! skybridge_profile_supports_requested_profile_backed_entitlements "$app_profile" "$expected_entitlements" || \
     ! skybridge_profile_supports_requested_profile_backed_entitlements "$app_profile" "$app_signed_entitlements" || \
     ! skybridge_profile_supports_requested_profile_backed_entitlements "$widget_profile" "$widget_signed_entitlements"; then
    echo "The iOS app or Widget embedded profile does not cover signed profile-backed entitlements." >&2
    return 1
  fi

  python3 "$verifier_path" \
    "$app_profile" \
    "$widget_profile" \
    "$app_signed_entitlements" \
    "$widget_signed_entitlements" \
    "$expected_entitlements" \
    "$app_leaf_certificate" \
    "$widget_leaf_certificate" \
    "$output_path" \
    "$app_signed_team_identifier" \
    "$app_bundle_identifier" \
    "$widget_bundle_identifier" \
    "$expected_team" \
    "$app_signing_authority_class" \
    "$widget_signing_authority_class" \
    "$configuration" \
    "$lab_run" \
    "$source_revision" \
    "$source_clean" \
    "$device_identifier" \
    "$selected_app_profile" \
    "$selected_widget_profile" \
    "1" \
    "$product_provenance_verified" \
    "$product_source_repository" \
    "$product_surface" \
    "$product_swift_conditions" \
    "$binary_test_surface_detected"
}
