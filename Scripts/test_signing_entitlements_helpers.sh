#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Scripts/signing_entitlements_helpers.sh
source "${SCRIPT_DIR}/signing_entitlements_helpers.sh"

fail() {
  echo "[test] $1" >&2
  exit 1
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-signing-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

SOURCE_ENTITLEMENTS="${TMP_DIR}/source.entitlements"
OUTPUT_ENTITLEMENTS="${TMP_DIR}/output.entitlements"
INFO_PLIST="${TMP_DIR}/Info.plist"
PROFILE_PLIST="${TMP_DIR}/profile.plist"

cat > "${SOURCE_ENTITLEMENTS}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.applesignin</key>
  <array>
    <string>Default</string>
  </array>
  <key>com.apple.security.network.client</key>
  <true/>
</dict>
</plist>
EOF

cat > "${INFO_PLIST}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>SKYBRIDGE_ENABLE_APPLE_SIGN_IN</key>
  <true/>
  <key>SKYBRIDGE_APPLE_SIGN_IN_MODE</key>
  <string>native</string>
  <key>SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN</key>
  <false/>
</dict>
</plist>
EOF

cat > "${PROFILE_PLIST}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Platform</key>
  <array>
    <string>OSX</string>
  </array>
  <key>TeamIdentifier</key>
  <array>
    <string>YKUPL7Z869</string>
  </array>
  <key>ApplicationIdentifierPrefix</key>
  <array>
    <string>YKUPL7Z869</string>
  </array>
  <key>Entitlements</key>
  <dict>
    <key>com.apple.application-identifier</key>
    <string>YKUPL7Z869.com.skybridge.compass.pro</string>
    <key>com.apple.developer.applesignin</key>
    <array>
      <string>Default</string>
    </array>
    <key>com.apple.security.application-groups</key>
    <array>
      <string>group.com.skybridge.compass</string>
    </array>
  </dict>
</dict>
</plist>
EOF

skybridge_prepare_signing_entitlements \
  "${SOURCE_ENTITLEMENTS}" \
  "${OUTPUT_ENTITLEMENTS}" \
  "${INFO_PLIST}" \
  ""

if skybridge_entitlements_request_applesignin "${OUTPUT_ENTITLEMENTS}"; then
  fail "prepare_signing_entitlements should strip Sign in with Apple entitlement when no matching profile is available and fallback is allowed"
fi

[[ "${SKYBRIDGE_SIGNING_EFFECTIVE_NATIVE_APPLE_SIGN_IN}" == "0" ]] \
  || fail "effective native Apple Sign In flag should be disabled when fallback stripping occurs"

[[ "${SKYBRIDGE_SIGNING_EFFECTIVE_APPLE_SIGN_IN_MODE}" == "web_session" ]] \
  || fail "effective Apple Sign In mode should switch to web_session when native entitlement is stripped"

[[ "$(skybridge_read_plist_bool "${INFO_PLIST}" "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN")" == "0" ]] \
  || fail "Info.plist native Apple Sign In flag should be false after fallback stripping"

[[ "$(skybridge_read_plist_string "${INFO_PLIST}" "SKYBRIDGE_APPLE_SIGN_IN_MODE")" == "web_session" ]] \
  || fail "Info.plist Apple Sign In mode should be web_session after fallback stripping"

cp "${SOURCE_ENTITLEMENTS}" "${OUTPUT_ENTITLEMENTS}"
if skybridge_profile_supports_requested_restricted_entitlements "" "${OUTPUT_ENTITLEMENTS}"; then
  fail "Apple Sign In should still be treated as a profile-backed restricted entitlement check when the entitlement is present"
fi

cat > "${SOURCE_ENTITLEMENTS}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>aps-environment</key>
  <string>development</string>
</dict>
</plist>
EOF

cp "${SOURCE_ENTITLEMENTS}" "${OUTPUT_ENTITLEMENTS}"
if skybridge_profile_supports_requested_profile_backed_entitlements "${PROFILE_PLIST}" "${OUTPUT_ENTITLEMENTS}"; then
  fail "Push notification aps-environment should require matching provisioning profile coverage"
fi

python3 - "${PROFILE_PLIST}" <<'PY'
import plistlib
import sys
from pathlib import Path

profile_path = Path(sys.argv[1])
with profile_path.open("rb") as fh:
    profile = plistlib.load(fh)
profile.setdefault("Entitlements", {})["aps-environment"] = "production"
with profile_path.open("wb") as fh:
    plistlib.dump(profile, fh)
PY

if skybridge_profile_supports_requested_profile_backed_entitlements "${PROFILE_PLIST}" "${OUTPUT_ENTITLEMENTS}"; then
  fail "Push notification aps-environment should reject provisioning profiles with the wrong environment"
fi

python3 - "${PROFILE_PLIST}" <<'PY'
import plistlib
import sys
from pathlib import Path

profile_path = Path(sys.argv[1])
with profile_path.open("rb") as fh:
    profile = plistlib.load(fh)
profile.setdefault("Entitlements", {})["aps-environment"] = "development"
with profile_path.open("wb") as fh:
    plistlib.dump(profile, fh)
PY

if ! skybridge_profile_supports_requested_profile_backed_entitlements "${PROFILE_PLIST}" "${OUTPUT_ENTITLEMENTS}"; then
  fail "Push notification aps-environment should pass when the provisioning profile matches the requested environment"
fi

cat > "${SOURCE_ENTITLEMENTS}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.com.skybridge.compass</string>
  </array>
</dict>
</plist>
EOF

cp "${SOURCE_ENTITLEMENTS}" "${OUTPUT_ENTITLEMENTS}"
if ! skybridge_profile_supports_requested_profile_backed_entitlements "${PROFILE_PLIST}" "${OUTPUT_ENTITLEMENTS}"; then
  fail "App Groups should be accepted when the provisioning profile covers the requested group"
fi

cat > "${SOURCE_ENTITLEMENTS}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>$(AppIdentifierPrefix)com.skybridge.compass.pro</string>
  <key>com.apple.developer.ubiquity-kvstore-identifier</key>
  <string>$(TeamIdentifierPrefix)com.skybridge.compass</string>
  <key>com.apple.security.network.client</key>
  <true/>
</dict>
</plist>
EOF

skybridge_prepare_signing_entitlements \
  "${SOURCE_ENTITLEMENTS}" \
  "${OUTPUT_ENTITLEMENTS}" \
  "${INFO_PLIST}" \
  "${PROFILE_PLIST}"

if grep -qF '$''(TeamIdentifierPrefix)' "${OUTPUT_ENTITLEMENTS}"; then
  fail "prepare_signing_entitlements should expand TeamIdentifierPrefix before codesign receives the entitlements"
fi

grep -q '<string>YKUPL7Z869.com.skybridge.compass</string>' "${OUTPUT_ENTITLEMENTS}" \
  || fail "expanded KVS entitlement should use the provisioning profile TeamIdentifier prefix"

grep -q '<string>YKUPL7Z869.com.skybridge.compass.pro</string>' "${OUTPUT_ENTITLEMENTS}" \
  || fail "expanded application identifier entitlement should use the provisioning profile AppIdentifier prefix"

if skybridge_profile_supports_requested_profile_backed_entitlements "${PROFILE_PLIST}" "${OUTPUT_ENTITLEMENTS}"; then
  fail "iCloud KVS coverage check should fail when the provisioning profile is missing the requested KVS entitlement"
fi

cat > "${PROFILE_PLIST}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Platform</key>
  <array>
    <string>OSX</string>
  </array>
  <key>TeamIdentifier</key>
  <array>
    <string>YKUPL7Z869</string>
  </array>
  <key>ApplicationIdentifierPrefix</key>
  <array>
    <string>YKUPL7Z869</string>
  </array>
  <key>Entitlements</key>
  <dict>
    <key>com.apple.application-identifier</key>
    <string>YKUPL7Z869.com.skybridge.compass.pro</string>
    <key>com.apple.developer.applesignin</key>
    <array>
      <string>Default</string>
    </array>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
      <string>iCloud.com.skybridge.compass</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <string>*</string>
    <key>com.apple.developer.ubiquity-container-identifiers</key>
    <array>
      <string>iCloud.com.skybridge.compass</string>
    </array>
    <key>com.apple.developer.ubiquity-kvstore-identifier</key>
    <string>YKUPL7Z869.*</string>
    <key>com.apple.security.application-groups</key>
    <array>
      <string>group.com.skybridge.compass</string>
    </array>
  </dict>
</dict>
</plist>
EOF

cat > "${SOURCE_ENTITLEMENTS}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>$(AppIdentifierPrefix)com.skybridge.compass.pro</string>
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array>
    <string>iCloud.com.skybridge.compass</string>
  </array>
  <key>com.apple.developer.icloud-services</key>
  <array>
    <string>CloudKit</string>
    <string>CloudDocuments</string>
  </array>
  <key>com.apple.developer.ubiquity-container-identifiers</key>
  <array>
    <string>iCloud.com.skybridge.compass</string>
  </array>
  <key>com.apple.developer.ubiquity-kvstore-identifier</key>
  <string>$(TeamIdentifierPrefix)com.skybridge.compass</string>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.com.skybridge.compass</string>
  </array>
</dict>
</plist>
EOF

skybridge_prepare_signing_entitlements \
  "${SOURCE_ENTITLEMENTS}" \
  "${OUTPUT_ENTITLEMENTS}" \
  "${INFO_PLIST}" \
  "${PROFILE_PLIST}"

if ! skybridge_profile_supports_requested_profile_backed_entitlements "${PROFILE_PLIST}" "${OUTPUT_ENTITLEMENTS}"; then
  fail "Developer ID profile wildcards should cover concrete iCloud services and KVS entitlements"
fi

if ! skybridge_profile_supports_requested_profile_backed_entitlements "${PROFILE_PLIST}" "${SOURCE_ENTITLEMENTS}"; then
  fail "profile coverage checks should expand TeamIdentifierPrefix placeholders before comparing profile-backed entitlements"
fi

cat > "${SOURCE_ENTITLEMENTS}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.com.skybridge.compass</string>
    <string>group.com.skybridge.extra</string>
  </array>
</dict>
</plist>
EOF

cp "${SOURCE_ENTITLEMENTS}" "${OUTPUT_ENTITLEMENTS}"
if skybridge_profile_supports_requested_profile_backed_entitlements "${PROFILE_PLIST}" "${OUTPUT_ENTITLEMENTS}"; then
  fail "App Groups coverage check should fail when the provisioning profile is missing one of the requested groups"
fi

cat > "${SOURCE_ENTITLEMENTS}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.device-information.user-assigned-device-name</key>
  <true/>
</dict>
</plist>
EOF

cp "${SOURCE_ENTITLEMENTS}" "${OUTPUT_ENTITLEMENTS}"
if skybridge_profile_supports_requested_profile_backed_entitlements "${PROFILE_PLIST}" "${OUTPUT_ENTITLEMENTS}"; then
  fail "user-assigned device name entitlement must require provisioning profile coverage"
fi

python3 - "${PROFILE_PLIST}" <<'PY'
import plistlib
import sys
from pathlib import Path

profile_path = Path(sys.argv[1])
with profile_path.open("rb") as fh:
    profile = plistlib.load(fh)
profile.setdefault("Entitlements", {})[
    "com.apple.developer.device-information.user-assigned-device-name"
] = True
with profile_path.open("wb") as fh:
    plistlib.dump(profile, fh)
PY

if ! skybridge_profile_supports_requested_profile_backed_entitlements "${PROFILE_PLIST}" "${OUTPUT_ENTITLEMENTS}"; then
  fail "user-assigned device name entitlement should pass when the profile explicitly covers it"
fi

cat > "${SOURCE_ENTITLEMENTS}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.applesignin</key>
  <array>
    <string>Default</string>
  </array>
  <key>com.apple.security.network.client</key>
  <true/>
</dict>
</plist>
EOF

cp "${SOURCE_ENTITLEMENTS}" "${OUTPUT_ENTITLEMENTS}"
if SKYBRIDGE_REQUIRE_APPLE_SIGN_IN=1 \
   skybridge_prepare_signing_entitlements \
     "${SOURCE_ENTITLEMENTS}" \
     "${OUTPUT_ENTITLEMENTS}" \
     "${INFO_PLIST}" \
     ""; then
  fail "prepare_signing_entitlements should fail in strict mode when no matching Apple Sign In profile is available"
fi

skybridge_prepare_signing_entitlements \
  "${SOURCE_ENTITLEMENTS}" \
  "${OUTPUT_ENTITLEMENTS}" \
  "${INFO_PLIST}" \
  "${PROFILE_PLIST}"

[[ "$(skybridge_read_plist_string "${INFO_PLIST}" "SKYBRIDGE_APPLE_SIGN_IN_MODE")" == "native" ]] \
  || fail "Info.plist Apple Sign In mode should be native when the provisioning profile supports the entitlement"

[[ "${SKYBRIDGE_SIGNING_EFFECTIVE_NATIVE_APPLE_SIGN_IN}" == "1" ]] \
  || fail "effective native Apple Sign In flag should be enabled when the provisioning profile supports the entitlement"

[[ "${SKYBRIDGE_SIGNING_EFFECTIVE_APPLE_SIGN_IN_MODE}" == "native" ]] \
  || fail "effective Apple Sign In mode should be native when the provisioning profile supports the entitlement"

if ! SKYBRIDGE_REQUIRE_APPLE_SIGN_IN_MODE=web_session \
   skybridge_prepare_signing_entitlements \
     "${SOURCE_ENTITLEMENTS}" \
     "${OUTPUT_ENTITLEMENTS}" \
     "${INFO_PLIST}" \
     "${PROFILE_PLIST}"; then
  fail "prepare_signing_entitlements should allow forcing web_session mode even when a profile supports native entitlement"
fi

[[ "$(skybridge_read_plist_string "${INFO_PLIST}" "SKYBRIDGE_APPLE_SIGN_IN_MODE")" == "web_session" ]] \
  || fail "forcing web_session mode should update Info.plist Apple Sign In mode"

echo "[test] signing entitlements helpers passed"
