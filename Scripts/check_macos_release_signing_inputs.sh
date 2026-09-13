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
[[ "$(rg -c '^-----BEGIN CERTIFICATE-----$' "$certificate")" == "1" ]] || {
  echo "signing P12 must contain exactly one client certificate" >&2; exit 1;
}
certificate_sha1="$(openssl x509 -in "$certificate" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
subject="$(openssl x509 -in "$certificate" -noout -subject -nameopt RFC2253)"
team_id="$(python3 - "$subject" <<'PY'
import re, sys
teams = re.findall(r'(?:^|,)OU=([A-Z0-9]{10})(?=,|$)', sys.argv[1].removeprefix("subject=").strip())
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
