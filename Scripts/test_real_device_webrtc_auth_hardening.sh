#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_SCRIPT="$ROOT_DIR/Scripts/run_real_device_webrtc_smoke.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-webrtc-auth-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 - "$SMOKE_SCRIPT" "$TMP_DIR" <<'PY'
import base64
import contextlib
import io
import json
import os
import pathlib
import stat
import sys
import time
import urllib.error
import urllib.request

script_path = pathlib.Path(sys.argv[1])
temporary_root = pathlib.Path(sys.argv[2])
script_source = script_path.read_text(encoding="utf-8")
begin_marker = "# SKYBRIDGE_AUTH_SESSION_PYTHON_BEGIN\n"
end_marker = "# SKYBRIDGE_AUTH_SESSION_PYTHON_END"
try:
    auth_source = script_source.split(begin_marker, 1)[1].split(end_marker, 1)[0]
except IndexError as exc:
    raise SystemExit("Unable to extract the real WebRTC auth-session helper") from exc


def encode_base64url(value):
    if isinstance(value, (dict, list)):
        value = json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def jwt(
    subject="fixture-user",
    issuer="https://project.supabase.co/auth/v1",
    role="authenticated",
    audience="authenticated",
    expires_in=3600,
    alg="HS256",
    tenant="fixture-tenant",
    extra_payload=None,
):
    signature_lengths = {"HS256": 32, "ES256": 64, "RS256": 256}
    signature = b"s" * signature_lengths.get(alg, 32)
    payload = {
        "aud": audience,
        "exp": time.time() + expires_in,
        "iss": issuer,
        "role": role,
        "sub": subject,
    }
    if tenant is not None:
        payload["tenant_id"] = tenant
    if extra_payload:
        payload.update(extra_payload)
    return ".".join(
        (
            encode_base64url({"alg": alg, "typ": "JWT"}),
            encode_base64url(payload),
            encode_base64url(signature),
        )
    )


class FakeResponse:
    def __init__(self, payload, status=200):
        self.status = status
        self.body = json.dumps(payload, separators=(",", ":")).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self, limit=-1):
        return self.body if limit < 0 else self.body[:limit]


class NetworkSpy:
    def __init__(self, responses=()):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        if not self.responses:
            raise AssertionError("Unexpected auth network request")
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


case_index = 0


def execute_helper(session_value, responses=(), supabase_url="https://project.supabase.co", source_mode=0o600):
    global case_index
    case_index += 1
    case_root = temporary_root / f"case-{case_index}"
    source_file = case_root / "source.json"
    output_dir = case_root / "private"
    output_file = output_dir / "host.auth-session.json"
    token_file = output_dir / "mac.token"
    tenant_file = output_dir / "mac.tenant"
    binding_file = output_dir / "mac.auth-binding.sha256"
    case_root.mkdir(mode=0o700)
    output_dir.mkdir(mode=0o700)
    source_file.write_text(json.dumps(session_value, separators=(",", ":")), encoding="utf-8")
    source_file.chmod(source_mode)
    output_file.write_text("sentinel", encoding="utf-8")
    output_file.chmod(0o600)
    spy = NetworkSpy(responses)
    saved_argv = sys.argv
    saved_environment = os.environ.copy()
    saved_build_opener = urllib.request.build_opener
    stdout = io.StringIO()
    error = None
    try:
        sys.argv = [
            "auth-helper",
            str(source_file),
            str(output_file),
            str(token_file),
            str(tenant_file),
            str(binding_file),
        ]
        os.environ.clear()
        os.environ.update(
            {
                "SUPABASE_ANON_KEY": "fixture-anon-key",
                "SUPABASE_URL": supabase_url,
            }
        )
        urllib.request.build_opener = lambda *handlers: spy
        namespace = {"__name__": "__main__"}
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            try:
                exec(compile(auth_source, "run_real_device_webrtc_smoke.auth.py", "exec"), namespace)
            except SystemExit as exc:
                error = str(exc)
    finally:
        urllib.request.build_opener = saved_build_opener
        os.environ.clear()
        os.environ.update(saved_environment)
        sys.argv = saved_argv
    return {
        "error": error,
        "output_dir": output_dir,
        "output_file": output_file,
        "token_file": token_file,
        "tenant_file": tenant_file,
        "binding_file": binding_file,
        "source_file": source_file,
        "spy": spy,
        "stdout": stdout.getvalue(),
    }


old_token = jwt(expires_in=-60)
new_token = jwt(expires_in=3600)
valid_session = {
    "accessToken": old_token,
    "refreshToken": "fixture-refresh-secret",
    "userIdentifier": "fixture-user",
}

# Malicious/insecure origins and mismatched issuers must fail before any auth request.
for malicious_url in (
    "http://project.supabase.co",
    "https://user:password@project.supabase.co",
    "https://project.supabase.co/auth/v1",
    "https://project.supabase.co?redirect=evil",
    "https://project.supabase.co#fragment",
    "https://project.supabase.co:8443",
):
    result = execute_helper(valid_session, supabase_url=malicious_url)
    assert result["error"], malicious_url
    assert not result["spy"].requests, malicious_url

issuer_mismatch = dict(valid_session, accessToken=jwt(issuer="https://evil.example/auth/v1"))
result = execute_helper(issuer_mismatch)
assert "issuer mismatch" in result["error"]
assert not result["spy"].requests

# Secret-bearing source files must be regular, private files with a JSON-object shape.
result = execute_helper(valid_session, source_mode=0o644)
assert "permissions" in result["error"]
assert not result["spy"].requests
result = execute_helper([])
assert "JSON object" in result["error"]
assert not result["spy"].requests
result = execute_helper({"userIdentifier": "fixture-user"})
assert "Auth token" in result["error"]
assert not result["spy"].requests

# Refresh responses are shape checked, and refreshed identity is bound before /user.
result = execute_helper(valid_session, responses=(FakeResponse([]),))
assert "refresh response is not a JSON object" in result["error"]
assert len(result["spy"].requests) == 1
result = execute_helper(valid_session, responses=(FakeResponse({}),))
assert "missing access_token" in result["error"]
assert len(result["spy"].requests) == 1
changed_subject = jwt(subject="attacker", expires_in=3600)
result = execute_helper(valid_session, responses=(FakeResponse({"access_token": changed_subject}),))
assert "changed bound identity claim: subject" in result["error"]
assert len(result["spy"].requests) == 1
changed_tenant = jwt(expires_in=3600, tenant="different-tenant")
result = execute_helper(valid_session, responses=(FakeResponse({"access_token": changed_tenant}),))
assert "changed bound identity claim: tenant" in result["error"]
assert len(result["spy"].requests) == 1
result = execute_helper(
    valid_session,
    responses=(FakeResponse({"access_token": new_token}), FakeResponse([])),
)
assert "/auth/v1/user response is not a JSON object" in result["error"]
assert len(result["spy"].requests) == 2

# Error messages must not echo an HTTP body, token, or refresh secret.
secret_body = b"response-body-must-not-leak"
http_error = urllib.error.HTTPError(
    "https://project.supabase.co/auth/v1/token?grant_type=refresh_token",
    401,
    "unauthorized",
    {},
    io.BytesIO(secret_body),
)
result = execute_helper(valid_session, responses=(http_error,))
assert "HTTP 401" in result["error"]
for secret in (secret_body.decode("ascii"), old_token, "fixture-refresh-secret"):
    assert secret not in result["error"]

# Successful refresh performs exactly the bound refresh then user lookup and atomically leaves mode 0600.
result = execute_helper(
    valid_session,
    responses=(
        FakeResponse({"access_token": new_token, "refresh_token": "rotated-refresh-secret"}),
        FakeResponse({"id": "fixture-user"}),
    ),
)
assert result["error"] is None, result["error"]
requests = [entry[0] for entry in result["spy"].requests]
assert [request.full_url for request in requests] == [
    "https://project.supabase.co/auth/v1/token?grant_type=refresh_token",
    "https://project.supabase.co/auth/v1/user",
]
assert requests[0].get_method() == "POST"
assert requests[1].get_method() == "GET"
assert stat.S_IMODE(result["output_dir"].stat().st_mode) == 0o700
assert stat.S_IMODE(result["output_file"].stat().st_mode) == 0o600
written = json.loads(result["output_file"].read_text(encoding="utf-8"))
assert written["accessToken"] == new_token
assert written["refreshToken"] == "rotated-refresh-secret"
assert written["nebulaId"] == "fixture-tenant"
assert result["token_file"].read_text(encoding="utf-8").strip() == new_token
assert result["tenant_file"].read_text(encoding="utf-8").strip() == "fixture-tenant"
binding = result["binding_file"].read_text(encoding="utf-8").strip()
assert len(binding) == 64 and all(character in "0123456789abcdef" for character in binding)
for private_value_path in (result["token_file"], result["tenant_file"], result["binding_file"]):
    assert stat.S_IMODE(private_value_path.stat().st_mode) == 0o600
assert not list(result["output_dir"].glob(".host.auth-session.*"))
assert not list(result["output_dir"].glob(".bootstrap-access-token.*"))
assert not list(result["output_dir"].glob(".bootstrap-tenant.*"))
assert not list(result["output_dir"].glob(".auth-binding.*"))

# A legacy session Nebula value is not a tenant authority when the verified JWT has no
# server-controlled tenant claim. The normalized copy drops it so runtime policy can
# use the verified subject fallback without weakening declared-tenant validation.
missing_tenant_token = jwt(tenant=None)
result = execute_helper(
    {
        "accessToken": missing_tenant_token,
        "userIdentifier": "fixture-user",
        "nebulaId": "fixture-tenant",
    },
    responses=(FakeResponse({"id": "fixture-user"}),),
)
assert result["error"] is None, result["error"]
assert len(result["spy"].requests) == 1
written = json.loads(result["output_file"].read_text(encoding="utf-8"))
assert written["userIdentifier"] == "fixture-user"
assert "nebulaId" not in written

# A caller-supplied session tenant remains strictly bound when the JWT does carry an
# explicit tenant claim.

mismatched_session_tenant = dict(
    valid_session,
    accessToken=new_token,
    refreshToken="",
    nebulaId="different-tenant",
)
result = execute_helper(
    mismatched_session_tenant,
    responses=(FakeResponse({"id": "fixture-user"}),),
)
assert "does not match the final JWT tenant claim" in result["error"]
assert len(result["spy"].requests) == 1

conflicting_tenant_token = jwt(
    extra_payload={"app_metadata": {"tenant_id": "different-tenant"}}
)
result = execute_helper(
    {"accessToken": conflicting_tenant_token, "userIdentifier": "fixture-user"}
)
assert "conflicting tenant claims" in result["error"]
assert not result["spy"].requests

# The actual redirect handler rejects both same-origin and cross-origin redirects.
definition_source = auth_source.split("\nsupabase_origin = normalize_supabase_origin", 1)[0]
saved_argv = sys.argv
try:
    sys.argv = ["auth-helper-definitions", "unused", "unused", "unused", "unused", "unused"]
    definitions = {"__name__": "auth_helper_definitions"}
    exec(compile(definition_source, "run_real_device_webrtc_smoke.auth.definitions.py", "exec"), definitions)
finally:
    sys.argv = saved_argv
handler = definitions["RejectAuthRedirects"]()
request = urllib.request.Request("https://project.supabase.co/auth/v1/user")
for redirect_url in (
    "https://project.supabase.co/auth/v1/user-next",
    "https://evil.example/steal-token",
):
    try:
        handler.redirect_request(request, None, 302, "Found", {}, redirect_url)
    except definitions["RedirectRejected"]:
        pass
    else:
        raise AssertionError(f"Redirect was not rejected: {redirect_url}")

print("WebRTC auth-session Python boundary fixtures passed")
PY

# Product outputs must be pre-created inside a private root and reject reuse/symlink substitution.
PRECREATE_OUTPUT_FUNCTION="$(sed -n '/^precreate_product_output_files() {$/,/^}$/p' "$SMOKE_SCRIPT")"
PRODUCT_OUTPUT_ROOT="$TMP_DIR/product-output"
mkdir -m 0700 "$PRODUCT_OUTPUT_ROOT"
(
  eval "$PRECREATE_OUTPUT_FUNCTION"
  ARTIFACT_DIR="$PRODUCT_OUTPUT_ROOT"
  MAC_STATUS="$PRODUCT_OUTPUT_ROOT/mac.status.log"
  MAC_CODE="$PRODUCT_OUTPUT_ROOT/mac.code"
  MAC_PQC_REPORT="$PRODUCT_OUTPUT_ROOT/mac.pqc.json"
  precreate_product_output_files
)
for output in mac.status.log mac.code mac.pqc.json; do
  [[ "$(stat -f '%Lp' "$PRODUCT_OUTPUT_ROOT/$output")" == "600" ]]
done
if (
  eval "$PRECREATE_OUTPUT_FUNCTION"
  ARTIFACT_DIR="$PRODUCT_OUTPUT_ROOT"
  MAC_STATUS="$PRODUCT_OUTPUT_ROOT/mac.status.log"
  MAC_CODE="$PRODUCT_OUTPUT_ROOT/mac.code"
  MAC_PQC_REPORT="$PRODUCT_OUTPUT_ROOT/mac.pqc.json"
  precreate_product_output_files
) >/dev/null 2>&1; then
  echo "Product output pre-creation unexpectedly accepted existing files" >&2
  exit 1
fi
SYMLINK_OUTPUT_ROOT="$TMP_DIR/product-output-symlink"
mkdir -m 0700 "$SYMLINK_OUTPUT_ROOT"
touch "$TMP_DIR/product-output-target"
chmod 0600 "$TMP_DIR/product-output-target"
ln -s "$TMP_DIR/product-output-target" "$SYMLINK_OUTPUT_ROOT/mac.status.log"
if (
  eval "$PRECREATE_OUTPUT_FUNCTION"
  export ARTIFACT_DIR="$SYMLINK_OUTPUT_ROOT"
  export MAC_STATUS="$SYMLINK_OUTPUT_ROOT/mac.status.log"
  export MAC_CODE="$SYMLINK_OUTPUT_ROOT/mac.code"
  export MAC_PQC_REPORT="$SYMLINK_OUTPUT_ROOT/mac.pqc.json"
  precreate_product_output_files
) >/dev/null 2>&1; then
  echo "Product output pre-creation unexpectedly followed a symlink" >&2
  exit 1
fi

# Exercise the exact shell lifecycle functions: EXIT removes every private auth value and the 0700 directory.
FUNCTIONS="$({
  sed -n '/^initialize_private_auth_session_dir() {$/,/^}$/p' "$SMOKE_SCRIPT"
  sed -n '/^destroy_private_auth_session() {$/,/^}$/p' "$SMOKE_SCRIPT"
})"
PRIVATE_DIR_RECORD="$TMP_DIR/private-dir-record"
(
  eval "$FUNCTIONS"
  AUTH_SESSION_FILE=""
  AUTH_PRIVATE_DIR=""
  MAC_CODE=""
  MAC_TOKEN=""
  MAC_TENANT=""
  MAC_AUTH_BINDING=""
  export AUTH_BINDING_DIGEST=""
  export ACCEPTANCE_CANDIDATE_READY=0
  IOS_BOOTSTRAP_SOURCE=""
  IOS_BOOTSTRAP_TOMBSTONE=""
  IOS_BOOTSTRAP_FILE_NAME="skybridge-webrtc-smoke-bootstrap-v1.json"
  trap destroy_private_auth_session EXIT
  initialize_private_auth_session_dir
  AUTH_SESSION_FILE="$AUTH_PRIVATE_DIR/host.auth-session.json"
  MAC_CODE="$AUTH_PRIVATE_DIR/mac.code"
  MAC_TOKEN="$AUTH_PRIVATE_DIR/mac.token"
  MAC_TENANT="$AUTH_PRIVATE_DIR/mac.tenant"
  MAC_AUTH_BINDING="$AUTH_PRIVATE_DIR/mac.auth-binding.sha256"
  umask 077
  : >"$AUTH_SESSION_FILE"
  : >"$MAC_CODE"
  : >"$MAC_TOKEN"
  : >"$MAC_TENANT"
  : >"$MAC_AUTH_BINDING"
  printf '%s\n' "$AUTH_PRIVATE_DIR" >"$PRIVATE_DIR_RECORD"
)
PRIVATE_DIR="$(<"$PRIVATE_DIR_RECORD")"
if [[ -e "$PRIVATE_DIR" ]]; then
  echo "EXIT cleanup left the private WebRTC auth directory behind: $PRIVATE_DIR" >&2
  exit 1
fi

# The one-time device bootstrap is a bounded private file; secrets never become launch arguments.
BOOTSTRAP_FUNCTION="$(sed -n '/^prepare_ios_bootstrap() {$/,/^}$/p' "$SMOKE_SCRIPT")"
BOOTSTRAP_FIXTURE_DIR="$TMP_DIR/bootstrap-fixture"
mkdir -p "$BOOTSTRAP_FIXTURE_DIR"
chmod 0700 "$BOOTSTRAP_FIXTURE_DIR"
python3 - "$BOOTSTRAP_FIXTURE_DIR" <<'PY'
import base64
import json
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])


def b64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


token = ".".join(
    (
        b64url(json.dumps({"alg": "HS256"}, separators=(",", ":")).encode()),
        b64url(json.dumps({"sub": "fixture-user", "tenant_id": "fixture-tenant"}, separators=(",", ":")).encode()),
        b64url(b"s" * 32),
    )
)
values = {
    "mac.code": "ABCDEFGH\n",
    "mac.token": token + "\n",
    "mac.tenant": "fixture-tenant\n",
}
for name, value in values.items():
    path = root / name
    path.write_text(value, encoding="utf-8")
    path.chmod(0o600)
(root / "mac.pqc.json").write_text(
    json.dumps(
        {
            "deviceId": "fixture-peer",
            "keys": [
                {
                    "suiteWireId": 1,
                    "publicKeyBase64": base64.b64encode(b"x" * 1216).decode("ascii"),
                }
            ],
        },
        separators=(",", ":"),
    ),
    encoding="utf-8",
)
(root / "mac.pqc.json").chmod(0o600)
PY
(
  eval "$BOOTSTRAP_FUNCTION"
  AUTH_PRIVATE_DIR="$BOOTSTRAP_FIXTURE_DIR"
  MAC_CODE="$BOOTSTRAP_FIXTURE_DIR/mac.code"
  MAC_TOKEN="$BOOTSTRAP_FIXTURE_DIR/mac.token"
  MAC_TENANT="$BOOTSTRAP_FIXTURE_DIR/mac.tenant"
  MAC_PQC_REPORT="$BOOTSTRAP_FIXTURE_DIR/mac.pqc.json"
  IOS_BOOTSTRAP_FILE_NAME="skybridge-webrtc-smoke-bootstrap-v1.json"
  IOS_BOOTSTRAP_SOURCE=""
  IOS_BOOTSTRAP_TOMBSTONE=""
  RUN_ID="fixture-run"
  SMOKE_TIMEOUT_SECONDS=240
  [[ -f "$MAC_PQC_REPORT" ]]
  [[ "$RUN_ID" == "fixture-run" ]]
  [[ "$SMOKE_TIMEOUT_SECONDS" -eq 240 ]]
  prepare_ios_bootstrap
  [[ "$(stat -f '%Lp' "$IOS_BOOTSTRAP_SOURCE")" == "600" ]]
  [[ "$(stat -f '%Lp' "$IOS_BOOTSTRAP_TOMBSTONE")" == "600" ]]
  python3 - "$IOS_BOOTSTRAP_SOURCE" "$IOS_BOOTSTRAP_TOMBSTONE" <<'PY'
import json
import pathlib
import sys

bootstrap = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
tombstone = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert bootstrap["schemaVersion"] == 1
assert bootstrap["runId"] == "fixture-run"
assert bootstrap["connectionCode"] == "ABCDEFGH"
assert bootstrap["tenantId"] == "fixture-tenant"
assert bootstrap["peerDeviceId"] == "fixture-peer"
assert bootstrap["peerKEMPublicKeys"][0]["suiteWireId"] == 1
assert tombstone == {
    "expiresAtEpochSeconds": 0,
    "runId": "consumed",
    "schemaVersion": 1,
    "state": "consumed",
}
serialized_tombstone = json.dumps(tombstone, sort_keys=True)
for secret in (bootstrap["accessToken"], bootstrap["connectionCode"], bootstrap["tenantId"]):
    assert secret not in serialized_tombstone
PY
)

# The release manifest is ineligible until cleanup monotonically finalizes private before public.
FINALIZER_FUNCTION="$(sed -n '/^finalize_release_acceptance_manifests_after_cleanup() {$/,/^}$/p' "$SMOKE_SCRIPT")"
FINALIZER_ARTIFACT_DIR="$TMP_DIR/finalizer-artifact"
FINALIZER_PUBLIC_DIR="$TMP_DIR/finalizer-public"
mkdir -m 0700 "$FINALIZER_ARTIFACT_DIR" "$FINALIZER_PUBLIC_DIR"
python3 - "$FINALIZER_ARTIFACT_DIR" "$FINALIZER_PUBLIC_DIR" <<'PY'
import json
import pathlib
import sys

payload = {
    "acceptanceEligible": False,
    "cleanupComplete": False,
    "diagnosticOnly": True,
    "iosBinaryTestSurfaceDetected": False,
    "iosProductSurface": "production",
    "iosProductionIdentityAlgorithm": "mldsa87",
    "iosProductionIdentityLifecycleVerified": True,
    "iosProductionIdentityProof": True,
    "iosProductionIdentityProtection": "secureEnclaveRequired",
    "iosProductionProduct": True,
    "iosSwiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
    "iosTestingCompilationCondition": False,
    "preCleanupCandidate": True,
    "schemaVersion": 1,
    "transport": "webrtc",
}
for root in map(pathlib.Path, sys.argv[1:]):
    path = root / "release-acceptance.json"
    path.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
(
  eval "$FINALIZER_FUNCTION"
  export ARTIFACT_DIR="$FINALIZER_ARTIFACT_DIR"
  export PUBLIC_ARTIFACT_DIR="$FINALIZER_PUBLIC_DIR"
  finalize_release_acceptance_manifests_after_cleanup
)
python3 - "$FINALIZER_ARTIFACT_DIR" "$FINALIZER_PUBLIC_DIR" <<'PY'
import json
import pathlib
import sys

payloads = [
    json.loads((pathlib.Path(root) / "release-acceptance.json").read_text(encoding="utf-8"))
    for root in sys.argv[1:]
]
assert payloads[0] == payloads[1]
assert payloads[0]["acceptanceEligible"] is True
assert payloads[0]["cleanupComplete"] is True
assert payloads[0]["diagnosticOnly"] is False
assert payloads[0]["preCleanupCandidate"] is True
assert payloads[0]["finalizationOrder"] == "private-then-public-v1"
PY

# A cleanup failure is observable: a successful run becomes failed, while an existing failure keeps its status.
CLEANUP_FUNCTIONS="$({
  sed -n '/^cleanup() {$/,/^}$/p' "$SMOKE_SCRIPT"
  sed -n '/^initialize_private_auth_session_dir() {$/,/^}$/p' "$SMOKE_SCRIPT"
  sed -n '/^destroy_private_auth_session() {$/,/^}$/p' "$SMOKE_SCRIPT"
  sed -n '/^overwrite_ios_bootstrap_with_tombstone() {$/,/^}$/p' "$SMOKE_SCRIPT"
})"
FAILED_CLEANUP_DIR_RECORD="$TMP_DIR/failed-cleanup-dir-record"
set +e
(
  eval "$CLEANUP_FUNCTIONS"
  eval 'copy_round_diagnostics() { :; }; terminate_ios_app() { :; }; copy_mac_media_diagnostics() { :; }; terminate_mac_host() { :; }; destroy_process_ownership_session() { :; }'
  IOS_CONSOLE_HANDLE_STARTED=0
  DID_COPY_IOS_BOOTSTRAP=0
  AUTH_SESSION_FILE=""
  AUTH_PRIVATE_DIR=""
  MAC_CODE=""
  MAC_TOKEN=""
  MAC_TENANT=""
  MAC_AUTH_BINDING=""
  export AUTH_BINDING_DIGEST=""
  export ACCEPTANCE_CANDIDATE_READY=0
  IOS_BOOTSTRAP_SOURCE=""
  IOS_BOOTSTRAP_TOMBSTONE=""
  IOS_BOOTSTRAP_FILE_NAME="skybridge-webrtc-smoke-bootstrap-v1.json"
  [[ "$DID_COPY_IOS_BOOTSTRAP" == "0" ]]
  [[ "$IOS_BOOTSTRAP_FILE_NAME" == "skybridge-webrtc-smoke-bootstrap-v1.json" ]]
  initialize_private_auth_session_dir
  : >"$AUTH_PRIVATE_DIR/unexpected-residue"
  printf '%s\n' "$AUTH_PRIVATE_DIR" >"$FAILED_CLEANUP_DIR_RECORD"
  cleanup
) >"$TMP_DIR/failed-cleanup.stdout" 2>"$TMP_DIR/failed-cleanup.stderr"
FAILED_CLEANUP_STATUS=$?
set -e
if [[ "$FAILED_CLEANUP_STATUS" -ne 1 ]]; then
  echo "Expected cleanup residue to fail an otherwise successful run; got $FAILED_CLEANUP_STATUS" >&2
  sed -n '1,80p' "$TMP_DIR/failed-cleanup.stderr" >&2
  exit 1
fi
grep -Fq "secret material may remain" "$TMP_DIR/failed-cleanup.stderr"
FAILED_CLEANUP_DIR="$(<"$FAILED_CLEANUP_DIR_RECORD")"
[[ -d "$FAILED_CLEANUP_DIR" ]]
rm -rf -- "$FAILED_CLEANUP_DIR"

PRESERVED_STATUS_DIR_RECORD="$TMP_DIR/preserved-status-dir-record"
set +e
(
  eval "$CLEANUP_FUNCTIONS"
  eval 'copy_round_diagnostics() { :; }; terminate_ios_app() { :; }; copy_mac_media_diagnostics() { :; }; terminate_mac_host() { :; }; destroy_process_ownership_session() { :; }'
  IOS_CONSOLE_HANDLE_STARTED=0
  DID_COPY_IOS_BOOTSTRAP=0
  AUTH_SESSION_FILE=""
  AUTH_PRIVATE_DIR=""
  MAC_CODE=""
  MAC_TOKEN=""
  MAC_TENANT=""
  MAC_AUTH_BINDING=""
  export AUTH_BINDING_DIGEST=""
  export ACCEPTANCE_CANDIDATE_READY=0
  IOS_BOOTSTRAP_SOURCE=""
  IOS_BOOTSTRAP_TOMBSTONE=""
  IOS_BOOTSTRAP_FILE_NAME="skybridge-webrtc-smoke-bootstrap-v1.json"
  trap cleanup EXIT
  initialize_private_auth_session_dir
  : >"$AUTH_PRIVATE_DIR/unexpected-residue"
  printf '%s\n' "$AUTH_PRIVATE_DIR" >"$PRESERVED_STATUS_DIR_RECORD"
  exit 42
) >"$TMP_DIR/preserved-status.stdout" 2>"$TMP_DIR/preserved-status.stderr"
PRESERVED_STATUS=$?
set -e
if [[ "$PRESERVED_STATUS" -ne 42 ]]; then
  echo "Expected cleanup to preserve original exit 42; got $PRESERVED_STATUS" >&2
  exit 1
fi
PRESERVED_STATUS_DIR="$(<"$PRESERVED_STATUS_DIR_RECORD")"
[[ -d "$PRESERVED_STATUS_DIR" ]]
rm -rf -- "$PRESERVED_STATUS_DIR"

# Prove that the compiler flag used by the macOS SwiftPM lane turns a real Swift warning into an error.
SWIFT_WARNING_FIXTURE="$TMP_DIR/warning-fixture.swift"
cat >"$SWIFT_WARNING_FIXTURE" <<'SWIFT'
@available(*, deprecated, message: "fixture warning")
func deprecatedFixture() {}
func exerciseFixture() { deprecatedFixture() }
SWIFT
if xcrun swiftc -typecheck -warnings-as-errors "$SWIFT_WARNING_FIXTURE" >"$TMP_DIR/swiftc.log" 2>&1; then
  echo "Expected -warnings-as-errors to reject the Swift warning fixture" >&2
  exit 1
fi
grep -Fq "error:" "$TMP_DIR/swiftc.log"
grep -Fq "deprecatedFixture" "$TMP_DIR/swiftc.log"
grep -Fq "fixture warning" "$TMP_DIR/swiftc.log"

# Prove the shared xcodebuild wrapper materializes both Swift and Clang warnings-as-errors settings.
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$SKYBRIDGE_XCODEBUILD_CAPTURE"
SH
chmod +x "$TMP_DIR/bin/xcodebuild"
source "$ROOT_DIR/Scripts/xcodebuild_helpers.sh"
SKYBRIDGE_XCODEBUILD_CAPTURE="$TMP_DIR/xcodebuild.args" \
PATH="$TMP_DIR/bin:$PATH" \
SKYBRIDGE_XCODE_WARNINGS_AS_ERRORS=1 \
  skybridge_run_xcodebuild -scheme AuthHardeningFixture build
grep -Fxq "SWIFT_SUPPRESS_WARNINGS=NO" "$TMP_DIR/xcodebuild.args"
grep -Fxq "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" "$TMP_DIR/xcodebuild.args"
grep -Fxq "GCC_TREAT_WARNINGS_AS_ERRORS=YES" "$TMP_DIR/xcodebuild.args"

# Source contracts tie the exercised policies to both production build invocations and the private boundary.
grep -Fq -- '-Xswiftc -warnings-as-errors' "$SMOKE_SCRIPT"
grep -Fq -- ") >\"\$MAC_BUILD_LOG\" 2>&1" "$SMOKE_SCRIPT"
grep -Fq -- "build >\"\$IOS_BUILD_LOG\" 2>&1" "$SMOKE_SCRIPT"
grep -Fq -- 'SKYBRIDGE_XCODE_WARNINGS_AS_ERRORS=1 skybridge_run_xcodebuild' "$SMOKE_SCRIPT"
grep -Fq -- 'skybridge_configure_optional_apple_pqc_sdk_compile_gate iphoneos' "$SMOKE_SCRIPT"
grep -Fq -- "MAC_CODE=\"\$ARTIFACT_DIR/mac.code\"" "$SMOKE_SCRIPT"
grep -Fq -- "MAC_TOKEN=\"\$AUTH_PRIVATE_DIR/mac.token\"" "$SMOKE_SCRIPT"
grep -Fq -- "MAC_TENANT=\"\$AUTH_PRIVATE_DIR/mac.tenant\"" "$SMOKE_SCRIPT"
grep -Fq -- "MAC_AUTH_BINDING=\"\$AUTH_PRIVATE_DIR/mac.auth-binding.sha256\"" "$SMOKE_SCRIPT"
grep -Fq -- 'umask 077' "$SMOKE_SCRIPT"
grep -Fq -- 'chmod 0700 "$ARTIFACT_DIR"' "$SMOKE_SCRIPT"
grep -Fq -- 'device copy to' "$SMOKE_SCRIPT"
grep -Fq -- '--domain-type appDataContainer' "$SMOKE_SCRIPT"
grep -Fq -- 'SKYBRIDGE_SMOKE_BOOTSTRAP_RUN_ID="$RUN_ID"' "$SMOKE_SCRIPT"
grep -Fq -- 'bootstrap-consumed run=${RUN_ID}' "$SMOKE_SCRIPT"
grep -Fq -- 'overwrite_ios_bootstrap_with_tombstone' "$SMOKE_SCRIPT"
grep -Fq -- 'trap cleanup EXIT' "$SMOKE_SCRIPT"
grep -Fq -- 'if ! destroy_private_auth_session; then' "$SMOKE_SCRIPT"
if grep -Fq -- 'destroy_private_auth_session || true' "$SMOKE_SCRIPT"; then
  echo "Private auth-session cleanup failures must not be suppressed" >&2
  exit 1
fi
if grep -Fq -- "MAC_TOKEN=\"\$ARTIFACT_DIR/" "$SMOKE_SCRIPT" \
  || grep -Fq -- "MAC_TENANT=\"\$ARTIFACT_DIR/" "$SMOKE_SCRIPT"; then
  echo "Secret macOS auth values must not be placed in the artifact tree" >&2
  exit 1
fi
if grep -Fq -- 'SKYBRIDGE_SMOKE_TOKEN_FILE=$MAC_TOKEN' "$SMOKE_SCRIPT" \
  || grep -Fq -- 'SKYBRIDGE_SMOKE_TENANT_FILE=$MAC_TENANT' "$SMOKE_SCRIPT"; then
  echo "The launched product/diagnostic host must not export auth values" >&2
  exit 1
fi

python3 - "$SMOKE_SCRIPT" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
launch_environment = source.split('IOS_ENV_JSON="$(\n', 1)[1].split('\n)"\n\nxcrun devicectl', 1)[0]
for forbidden in (
    "SKYBRIDGE_ACCESS_TOKEN",
    "SKYBRIDGE_TENANT_ID",
    "SKYBRIDGE_SMOKE_CONNECT_CODE",
    "SKYBRIDGE_PQC_PEER_DEVICE_ID",
    "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64",
):
    assert forbidden not in launch_environment, forbidden
assert "SKYBRIDGE_SMOKE_BOOTSTRAP_RUN_ID" in launch_environment
PY

# Raw devicectl launch context remains private; only a secret-free summary enters public artifacts.
source "$ROOT_DIR/Scripts/real_device_smoke_redaction.sh"
RAW_LAUNCH_DIR="$TMP_DIR/raw-launch-artifacts"
PRIVATE_LAUNCH_DIR="$TMP_DIR/private-launch"
PUBLIC_LAUNCH_DIR="$TMP_DIR/public-launch"
mkdir -p "$RAW_LAUNCH_DIR" "$PRIVATE_LAUNCH_DIR"
cat >"$PRIVATE_LAUNCH_DIR/ios-launch.raw.json" <<'JSON'
{"result":{"environmentVariables":{"SKYBRIDGE_ACCESS_TOKEN":"launch-access-token-secret","SKYBRIDGE_TENANT_ID":"launch-tenant-secret"},"process":{"processIdentifier":1234}}}
JSON
cat >"$RAW_LAUNCH_DIR/ios-launch.json" <<'JSON'
{"bundleIdentifier":"com.skybridge.compass.ios","launched":true,"rawLaunchContextRetained":false,"schemaVersion":1}
JSON
skybridge_smoke_materialize_public_artifacts fixture "$RAW_LAUNCH_DIR" "$PUBLIC_LAUNCH_DIR"
skybridge_smoke_check_public_artifacts "$PUBLIC_LAUNCH_DIR"
if grep -RFq -- "launch-access-token-secret" "$RAW_LAUNCH_DIR" "$PUBLIC_LAUNCH_DIR"; then
  echo "Access token leaked through public launch JSON redaction" >&2
  exit 1
fi
grep -Fq '"rawLaunchContextRetained": false' "$PUBLIC_LAUNCH_DIR/ios-launch.json"

echo "Real-device WebRTC auth hardening fixtures passed"
