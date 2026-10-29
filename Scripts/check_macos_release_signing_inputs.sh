#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/signing_entitlements_helpers.sh"

[[ $# == 3 ]] || { echo "expected public signing certificate, app profile and widget profile" >&2; exit 2; }
certificate="$1"
app_profile="$2"
widget_profile="$3"
for path in "$certificate" "$app_profile" "$widget_profile"; do
  [[ -f "$path" && ! -L "$path" ]] || { echo "signing input must be a real file" >&2; exit 1; }
done
umask 077
certificate_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-public-certificates.XXXXXX")"
trap '/bin/rm -rf "$certificate_dir"' EXIT
app_hashes="$(skybridge_developer_id_distribution_profile_certificate_hashes "$app_profile")"
widget_hashes="$(skybridge_developer_id_distribution_profile_certificate_hashes "$widget_profile")"
profile_hashes="$(python3 - "$app_hashes" "$widget_hashes" <<'PY'
import sys
print("\n".join(sorted(set(sys.argv[1].splitlines()) & set(sys.argv[2].splitlines()))))
PY
)"
authority_hashes="$(python3 - "$certificate" "$certificate_dir" <<'PY'
import base64, hashlib, re, sys
from pathlib import Path

raw = Path(sys.argv[1]).read_bytes()
if len(raw) > 1024 * 1024 or b"PRIVATE KEY-----" in raw:
    raise SystemExit("expected a bounded public certificate bundle without private keys")
blocks = re.findall(rb"-----BEGIN CERTIFICATE-----\s+([A-Za-z0-9+/=\s]+?)\s+-----END CERTIFICATE-----", raw)
if not 1 <= len(blocks) <= 64 or raw.count(b"-----BEGIN CERTIFICATE-----") != len(blocks):
    raise SystemExit("public certificate bundle is empty or malformed")
hashes = set()
for block in blocks:
    encoded = re.sub(rb"\s", b"", block)
    der = base64.b64decode(encoded, validate=True)
    fingerprint = hashlib.sha1(der).hexdigest().upper()
    if fingerprint not in hashes:
        (Path(sys.argv[2]) / (fingerprint + ".pem")).write_bytes(
            b"-----BEGIN CERTIFICATE-----\n" + base64.encodebytes(der)
            + b"-----END CERTIFICATE-----\n"
        )
        hashes.add(fingerprint)
print("\n".join(sorted(hashes)))
PY
)"
certificate_sha1="$(skybridge_select_unique_profile_bound_codesign_identity_hash "$authority_hashes" "$profile_hashes")"
certificate="$certificate_dir/$certificate_sha1.pem"
openssl x509 -in "$certificate" -noout -checkend 0 >/dev/null
subject="$(openssl x509 -in "$certificate" -noout -subject -nameopt RFC2253)"
team_id="$(python3 - "$subject" <<'PY'
import re, sys
subject = sys.argv[1].removeprefix("subject=").strip()
if not re.search(r'(?:^|,)CN=Developer ID Application:', subject):
    raise SystemExit("profile-bound certificate is not a Developer ID Application identity")
teams = re.findall(r'(?:^|,)OU=([A-Z0-9]{10})(?=,|$)', subject)
if len(teams) != 1:
    raise SystemExit("signing certificate must contain one Apple team OU")
print(teams[0])
PY
)"
[[ "$certificate_sha1" =~ ^[A-Fa-f0-9]{40}$ ]] || { echo "invalid signing certificate fingerprint" >&2; exit 1; }
echo "Developer ID certificate fingerprint: $certificate_sha1"
for target in app widget; do
  if [[ "$target" == app ]]; then
    profile="$app_profile"
    bundle_id="com.skybridge.compass.pro"
    entitlements="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements"
  else
    profile="$widget_profile"
    bundle_id="com.skybridge.compass.pro.widgets"
    entitlements="$PROJECT_ROOT/Sources/SkyBridgeCompassWidgets/SkyBridgeCompassWidgetsExtension.entitlements"
  fi
  echo "Validating $target Developer ID profile"
  shasum -a 256 "$profile"
  skybridge_validate_provisionprofile_app_identity "$profile" "$bundle_id" "$team_id"
  skybridge_profile_supports_requested_restricted_entitlements "$profile" "$entitlements"
  skybridge_validate_developer_id_distribution_profile_certificate "$profile" "$certificate_sha1"
done
echo "Developer ID signing inputs verified"
