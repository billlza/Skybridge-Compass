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

DEVELOPER_ID_PROFILE="${TMP_DIR}/developer-id-profile.plist"
DEVELOPER_CERT_SHA1="$(python3 - "${DEVELOPER_ID_PROFILE}" <<'PY'
import datetime as dt
import hashlib
import plistlib
import sys
from pathlib import Path

certificate = b"skybridge-test-developer-id-certificate"
profile = {
    "Platform": ["OSX"],
    "ProvisionsAllDevices": True,
    "ExpirationDate": dt.datetime.now() + dt.timedelta(days=1),
    "DeveloperCertificates": [certificate],
    "Entitlements": {},
}
Path(sys.argv[1]).write_bytes(plistlib.dumps(profile))
print(hashlib.sha1(certificate).hexdigest().upper())
PY
)"

if ! skybridge_validate_developer_id_distribution_profile_certificate \
  "${DEVELOPER_ID_PROFILE}" \
  "${DEVELOPER_CERT_SHA1}"; then
  fail "current Developer ID distribution profile should accept its embedded certificate fingerprint"
fi

if skybridge_validate_developer_id_distribution_profile_certificate \
  "${DEVELOPER_ID_PROFILE}" \
  "0000000000000000000000000000000000000000"; then
  fail "Developer ID distribution profile must reject a certificate fingerprint absent from DeveloperCertificates"
fi

python3 - "${DEVELOPER_ID_PROFILE}" <<'PY'
import datetime as dt
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
profile = plistlib.loads(path.read_bytes())
profile["ExpirationDate"] = dt.datetime.now() - dt.timedelta(days=1)
path.write_bytes(plistlib.dumps(profile))
PY
if skybridge_validate_developer_id_distribution_profile_certificate \
  "${DEVELOPER_ID_PROFILE}" \
  "${DEVELOPER_CERT_SHA1}"; then
  fail "expired Developer ID distribution profile must fail closed"
fi

python3 - "${DEVELOPER_ID_PROFILE}" <<'PY'
import datetime as dt
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
profile = plistlib.loads(path.read_bytes())
profile["ExpirationDate"] = dt.datetime.now() + dt.timedelta(days=1)
profile["Entitlements"]["get-task-allow"] = False
path.write_bytes(plistlib.dumps(profile))
PY
if skybridge_validate_developer_id_distribution_profile_certificate \
  "${DEVELOPER_ID_PROFILE}" \
  "${DEVELOPER_CERT_SHA1}"; then
  fail "Developer ID distribution profile must reject any get-task-allow entitlement"
fi

python3 - "${DEVELOPER_ID_PROFILE}" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
profile = plistlib.loads(path.read_bytes())
profile["Entitlements"].pop("get-task-allow", None)
profile["ProvisionedDevices"] = ["test-device"]
path.write_bytes(plistlib.dumps(profile))
PY
if skybridge_validate_developer_id_distribution_profile_certificate \
  "${DEVELOPER_ID_PROFILE}" \
  "${DEVELOPER_CERT_SHA1}"; then
  fail "Developer ID distribution profile must reject a device allow-list"
fi

OLD_CERT_SHA1="1111111111111111111111111111111111111111"
NEW_CERT_SHA1="2222222222222222222222222222222222222222"
selected_hash="$(
  skybridge_select_unique_profile_bound_codesign_identity_hash \
    "${OLD_CERT_SHA1}"$'\n'"${NEW_CERT_SHA1}" \
    "${NEW_CERT_SHA1}"
)"
[[ "${selected_hash}" == "${NEW_CERT_SHA1}" ]] \
  || fail "profile intersection should select the one current certificate among same-authority renewal candidates"

if skybridge_select_unique_profile_bound_codesign_identity_hash \
  "${OLD_CERT_SHA1}"$'\n'"${NEW_CERT_SHA1}" \
  "${OLD_CERT_SHA1}"$'\n'"${NEW_CERT_SHA1}"; then
  fail "profile intersection must reject multiple current same-authority certificates"
fi

echo "[test] signing entitlements helpers passed"
