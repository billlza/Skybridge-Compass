#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-release-preflight.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" && \
      -d "$HOME/Library/Android/sdk" ]]; then
  export ANDROID_HOME="$HOME/Library/Android/sdk"
fi

GRADLE=(
  "$ROOT_DIR/gradlew"
  --no-daemon
  --no-configuration-cache
  --console=plain
)
RUNTIME_ENV=(
  "SUPABASE_URL=https://release-preflight.invalid"
  "SUPABASE_ANON_KEY=release-preflight-test-key"
)
UNSET_SIGNING=(
  -u KEYSTORE_PATH
  -u KEYSTORE_PASSWORD
  -u KEY_ALIAS
  -u KEY_PASSWORD
)

fail() {
  echo "release artifact preflight test failed: $*" >&2
  exit 1
}

run_without_signing() {
  env "${UNSET_SIGNING[@]}" "${RUNTIME_ENV[@]}" "${GRADLE[@]}" "$@"
}

assert_guarded_graph() {
  local entry_point="$1"
  local output="$TMP_DIR/graph-${entry_point//[^A-Za-z0-9]/_}.txt"
  run_without_signing --dry-run "$entry_point" >"$output" 2>&1 || {
    sed -n '1,200p' "$output" >&2
    fail "$entry_point task graph could not be resolved"
  }
  grep -Fq ':app:verifyReleaseArtifactConfiguration' "$output" || {
    sed -n '1,200p' "$output" >&2
    fail "$entry_point bypassed release artifact preflight"
  }
}

assert_unguarded_non_artifact_graph() {
  local entry_point="$1"
  local output="$TMP_DIR/non-artifact-${entry_point//[^A-Za-z0-9]/_}.txt"
  env "${UNSET_SIGNING[@]}" -u SUPABASE_URL -u SUPABASE_ANON_KEY \
    "${GRADLE[@]}" --dry-run "$entry_point" >"$output" 2>&1 || {
    sed -n '1,200p' "$output" >&2
    fail "$entry_point task graph could not be resolved"
  }
  if grep -Fq ':app:verifyReleaseArtifactConfiguration' "$output"; then
    sed -n '1,200p' "$output" >&2
    fail "$entry_point must remain usable without release credentials"
  fi
}

for entry_point in \
  ':app:assembleRelease' \
  ':app:aR' \
  ':app:bundleRelease' \
  ':app:bR' \
  ':app:assemble' \
  ':app:packageRelease' \
  ':app:installRelease'; do
  assert_guarded_graph "$entry_point"
done

source_binding_output="$TMP_DIR/source-binding-graph.txt"
run_without_signing --dry-run :app:assembleRelease >"$source_binding_output" 2>&1
grep -Fq ':app:generateReleaseSourceBinding' "$source_binding_output" || {
  sed -n '1,200p' "$source_binding_output" >&2
  fail 'release APK graph omitted clean Git source binding generation'
}
grep -Fq ':app:generateReleaseApkAuditMetadata' "$source_binding_output" || {
  sed -n '1,200p' "$source_binding_output" >&2
  fail 'release APK graph omitted APK/mapping audit metadata generation'
}

aab_binding_output="$TMP_DIR/aab-binding-graph.txt"
run_without_signing --dry-run :app:bundleRelease >"$aab_binding_output" 2>&1
grep -Fq ':app:generateReleaseSourceBinding' "$aab_binding_output" || {
  sed -n '1,200p' "$aab_binding_output" >&2
  fail 'release AAB graph omitted clean Git source binding generation'
}
grep -Fq ':app:generateReleaseAabAuditMetadata' "$aab_binding_output" || {
  sed -n '1,200p' "$aab_binding_output" >&2
  fail 'release AAB graph omitted AAB/mapping audit metadata generation'
}

# Compilation and lint do not emit a distributable artifact, so they intentionally do not require
# runtime secrets or signing credentials. Every APK/AAB/install path above remains guarded.
assert_unguarded_non_artifact_graph ':app:compileReleaseKotlin'
assert_unguarded_non_artifact_graph ':app:lintRelease'

missing_output="$TMP_DIR/missing-signing.txt"
if run_without_signing :app:verifyReleaseArtifactConfiguration >"$missing_output" 2>&1; then
  fail 'missing signing credentials unexpectedly passed'
fi
grep -Fq 'missing: KEYSTORE_PATH, KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD' "$missing_output" || {
  sed -n '1,200p' "$missing_output" >&2
  fail 'missing signing failure was not explicit'
}

partial_output="$TMP_DIR/partial-signing.txt"
if env \
  -u KEYSTORE_PASSWORD -u KEY_ALIAS -u KEY_PASSWORD \
  "${RUNTIME_ENV[@]}" \
  KEYSTORE_PATH="$TMP_DIR/not-used.p12" \
  "${GRADLE[@]}" :app:verifyReleaseArtifactConfiguration >"$partial_output" 2>&1; then
  fail 'partial signing credentials unexpectedly passed'
fi
grep -Fq 'missing: KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD' "$partial_output" || {
  sed -n '1,200p' "$partial_output" >&2
  fail 'partial signing failure was not explicit'
}

if [[ ! -f "$ROOT_DIR/local.properties" ]]; then
  runtime_output="$TMP_DIR/missing-runtime.txt"
  if env "${UNSET_SIGNING[@]}" -u SUPABASE_URL -u SUPABASE_ANON_KEY "${GRADLE[@]}" \
    :app:verifyReleaseArtifactConfiguration >"$runtime_output" 2>&1; then
    fail 'missing release runtime config unexpectedly passed'
  fi
  grep -Fq 'requires SUPABASE_URL and SUPABASE_ANON_KEY' "$runtime_output" || {
    sed -n '1,200p' "$runtime_output" >&2
    fail 'missing runtime config failure was not explicit'
  }
fi

KEYSTORE_PASSWORD_VALUE='release-preflight-password'
keytool -genkeypair \
  -alias release-preflight \
  -keystore "$TMP_DIR/release-preflight.p12" \
  -storetype PKCS12 \
  -storepass "$KEYSTORE_PASSWORD_VALUE" \
  -keypass "$KEYSTORE_PASSWORD_VALUE" \
  -keyalg RSA \
  -keysize 2048 \
  -validity 1 \
  -dname 'CN=Release Preflight Test' \
  -noprompt >"$TMP_DIR/keytool.txt" 2>&1

env \
  "${RUNTIME_ENV[@]}" \
  KEYSTORE_PATH="$TMP_DIR/release-preflight.p12" \
  KEYSTORE_PASSWORD="$KEYSTORE_PASSWORD_VALUE" \
  KEY_ALIAS='release-preflight' \
  KEY_PASSWORD="$KEYSTORE_PASSWORD_VALUE" \
  "${GRADLE[@]}" :app:verifyReleaseArtifactConfiguration >"$TMP_DIR/valid.txt" 2>&1 || {
    sed -n '1,200p' "$TMP_DIR/valid.txt" >&2
    fail 'valid release identity did not pass'
  }

invalid_alias_output="$TMP_DIR/invalid-alias.txt"
if env \
  "${RUNTIME_ENV[@]}" \
  KEYSTORE_PATH="$TMP_DIR/release-preflight.p12" \
  KEYSTORE_PASSWORD="$KEYSTORE_PASSWORD_VALUE" \
  KEY_ALIAS='missing-alias' \
  KEY_PASSWORD="$KEYSTORE_PASSWORD_VALUE" \
  "${GRADLE[@]}" :app:verifyReleaseArtifactConfiguration >"$invalid_alias_output" 2>&1; then
  fail 'invalid signing alias unexpectedly passed'
fi
grep -Fq 'KEY_ALIAS must identify a private-key entry' "$invalid_alias_output" || {
  sed -n '1,200p' "$invalid_alias_output" >&2
  fail 'invalid alias failure was not explicit'
}

echo 'release artifact preflight tests passed'
