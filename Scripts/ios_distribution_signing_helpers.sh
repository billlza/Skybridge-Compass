#!/usr/bin/env bash

# Shared iOS App + Widget distribution signing proof used by every physical release lane.
# The caller must source signing_entitlements_helpers.sh first.

skybridge_archive_ios_distribution_product() {
  if (( $# < 7 )); then
    echo "skybridge_archive_ios_distribution_product requires at least 7 arguments" >&2
    return 2
  fi

  local project_path="$1"
  local scheme="$2"
  local archive_path="$3"
  local derived_data_path="$4"
  local archive_log="$5"
  local provisioning_policy="$6"
  local separator="$7"
  shift 7

  if [[ "$provisioning_policy" != "installed-only" || "$separator" != "--" ]]; then
    echo "iOS archive provisioning policy must be installed-only and followed by --" >&2
    return 2
  fi
  if [[ "$project_path" != /* || ! -d "$project_path" || -L "$project_path" ]]; then
    echo "iOS archive project must be an absolute, non-symlink directory" >&2
    return 1
  fi
  if [[ -z "$scheme" || "$archive_path" != /* || "$derived_data_path" != /* || "$archive_log" != /* ]]; then
    echo "iOS archive inputs must use a named scheme and absolute output paths" >&2
    return 2
  fi
  if [[ -e "$archive_path" || -L "$archive_path" || \
        -e "$derived_data_path" || -L "$derived_data_path" || \
        -e "$archive_log" || -L "$archive_log" ]]; then
    echo "iOS archive outputs must be fresh" >&2
    return 1
  fi
  if ! declare -F skybridge_run_xcodebuild >/dev/null; then
    echo "skybridge_run_xcodebuild must be loaded before archiving an iOS product" >&2
    return 2
  fi

  local setting
  for setting in "$@"; do
    case "$setting" in
      -allowProvisioningUpdates|-allowProvisioningDeviceRegistration|\
      CODE_SIGN_STYLE=*|CODE_SIGN_IDENTITY=*|PROVISIONING_PROFILE=*|\
      PROVISIONING_PROFILE_SPECIFIER=*|\
      SKYBRIDGE_IOS_APP_DISTRIBUTION_PROFILE_SPECIFIER=*|\
      SKYBRIDGE_IOS_WIDGET_DISTRIBUTION_PROFILE_SPECIFIER=*)
        echo "Caller attempted to override the installed-only Automatic signing boundary" >&2
        return 2
        ;;
      *=*) ;;
      *)
        echo "iOS archive extras must be explicit build-setting assignments" >&2
        return 2
        ;;
    esac
  done

  local archive_parent
  local derived_parent
  local log_parent
  local output_parent
  archive_parent="$(dirname "$archive_path")"
  derived_parent="$(dirname "$derived_data_path")"
  log_parent="$(dirname "$archive_log")"
  for output_parent in "$archive_parent" "$derived_parent" "$log_parent"; do
    if [[ ! -d "$output_parent" || -L "$output_parent" ]]; then
      echo "iOS archive output parents must already exist and must not be symlinks" >&2
      return 1
    fi
  done

  if ! (
    unset CODE_SIGN_IDENTITY
    unset PROVISIONING_PROFILE
    unset PROVISIONING_PROFILE_SPECIFIER
    SKYBRIDGE_XCODE_WARNINGS_AS_ERRORS=1 \
      skybridge_run_xcodebuild archive \
        -project "$project_path" \
        -scheme "$scheme" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$archive_path" \
        -derivedDataPath "$derived_data_path" \
        "$@" \
        "CODE_SIGN_STYLE=Automatic" \
        "SKYBRIDGE_IOS_APP_DISTRIBUTION_PROFILE_SPECIFIER=" \
        "SKYBRIDGE_IOS_WIDGET_DISTRIBUTION_PROFILE_SPECIFIER="
  ) >"$archive_log" 2>&1; then
    echo "Automatic iOS archive failed; retained log: $archive_log" >&2
    return 1
  fi
  if LC_ALL=C grep -Eiq \
    '(^|[^[:alpha:]])(warning|error):|ARCHIVE FAILED|BUILD FAILED' \
    "$archive_log"; then
    echo "Automatic iOS archive log contains a warning or error" >&2
    return 1
  fi
  if [[ ! -d "$archive_path" || -L "$archive_path" || ! -f "$archive_path/Info.plist" ]]; then
    echo "Automatic iOS archive did not produce the expected archive" >&2
    return 1
  fi
}

skybridge_export_ios_distribution_archive() {
  if (( $# != 6 )); then
    echo "skybridge_export_ios_distribution_archive requires 6 arguments" >&2
    return 2
  fi

  local archive_path="$1"
  local export_options="$2"
  local export_dir="$3"
  local export_log="$4"
  local expected_team="$5"
  local provisioning_policy="$6"
  local export_method
  local signing_style
  local export_team
  local manage_build_number

  if [[ "$provisioning_policy" != "installed-only" ]]; then
    echo "iOS export provisioning policy must be installed-only" >&2
    return 2
  fi
  if [[ "$archive_path" != /* || ! -d "$archive_path" || -L "$archive_path" || \
        ! -f "$archive_path/Info.plist" ]]; then
    echo "iOS export requires an absolute, non-symlink archive" >&2
    return 1
  fi
  if [[ "$export_options" != /* || ! -f "$export_options" || -L "$export_options" || \
        "$export_dir" != /* || "$export_log" != /* || -z "$expected_team" ]]; then
    echo "iOS export requires absolute, non-symlink inputs and outputs" >&2
    return 2
  fi
  if [[ -e "$export_dir" || -L "$export_dir" || -e "$export_log" || -L "$export_log" ]]; then
    echo "iOS export outputs must be fresh" >&2
    return 1
  fi
  export_method="$(/usr/libexec/PlistBuddy -c 'Print :method' "$export_options" 2>/dev/null || true)"
  signing_style="$(/usr/libexec/PlistBuddy -c 'Print :signingStyle' "$export_options" 2>/dev/null || true)"
  export_team="$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$export_options" 2>/dev/null || true)"
  manage_build_number="$(/usr/libexec/PlistBuddy -c 'Print :manageAppVersionAndBuildNumber' "$export_options" 2>/dev/null || true)"
  if [[ "$export_method" != "release-testing" || "$signing_style" != "automatic" || \
        "$export_team" != "$expected_team" || "$manage_build_number" != "false" ]]; then
    echo "iOS export options violate the release-testing Automatic signing contract" >&2
    return 1
  fi
  if [[ ! -d "$(dirname "$export_dir")" || -L "$(dirname "$export_dir")" || \
        ! -d "$(dirname "$export_log")" || -L "$(dirname "$export_log")" ]]; then
    echo "iOS export output parents must already exist and must not be symlinks" >&2
    return 1
  fi

  if ! (
    unset CODE_SIGN_IDENTITY
    unset PROVISIONING_PROFILE
    unset PROVISIONING_PROFILE_SPECIFIER
    xcodebuild -exportArchive \
      -archivePath "$archive_path" \
      -exportOptionsPlist "$export_options" \
      -exportPath "$export_dir"
  ) >"$export_log" 2>&1; then
    echo "Automatic iOS archive export failed; retained log: $export_log" >&2
    return 1
  fi
  if LC_ALL=C grep -Eiq \
    '(^|[^[:alpha:]])(warning|error):|EXPORT FAILED|BUILD FAILED' \
    "$export_log"; then
    echo "Automatic iOS export log contains a warning or error" >&2
    return 1
  fi
  if [[ ! -d "$export_dir" || -L "$export_dir" ]]; then
    echo "Automatic iOS export did not produce the expected directory" >&2
    return 1
  fi
}

skybridge_extract_single_ios_exported_app() {
  if (( $# != 3 )); then
    echo "skybridge_extract_single_ios_exported_app requires 3 arguments" >&2
    return 2
  fi
  local extractor="$1"
  local export_dir="$2"
  local destination_app="$3"
  local extracted_app

  if [[ ! -f "$extractor" || -L "$extractor" || ! -x "$extractor" ]]; then
    echo "The iOS IPA extractor is missing, linked, or not executable" >&2
    return 1
  fi
  if ! extracted_app="$(
    python3 "$extractor" \
      --export-dir "$export_dir" \
      --destination-app "$destination_app"
  )"; then
    return 1
  fi
  if [[ "$extracted_app" != "$destination_app" || ! -d "$extracted_app" || -L "$extracted_app" ]]; then
    echo "The iOS IPA extractor returned an unexpected application path" >&2
    return 1
  fi
  printf '%s\n' "$extracted_app"
}

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
  if ! /usr/bin/codesign --display --extract-certificates="$app_certificate_prefix" "$app_path" >/dev/null 2>&1 || \
     [[ ! -s "$app_leaf_certificate" ]] || \
     ! /usr/bin/codesign --display --extract-certificates="$widget_certificate_prefix" "$widget_path" >/dev/null 2>&1 || \
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
    "$binary_test_surface_detected" \
    "$app_path/Info.plist" \
    "$widget_path/Info.plist"
}
