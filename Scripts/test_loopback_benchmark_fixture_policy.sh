#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTIFICATE_PATH="Tests/Fixtures/loopback_test_server_certificate.der"
PRIVATE_KEY_PATH="Tests/Fixtures/loopback_test_server_private_key.x963"
CERTIFICATE_SHA256="b745f9d72a335f1c92444209ecb052dba0dd1f11a534b2a8dbe5ab95b5c35f24"
PRIVATE_KEY_SHA256="1e3552f72f70f7fd0ae2c23ee126f3895efe989af22485ebc784a504ebdfbb87"
BENCHMARK_SUPPORT_FILES=(
  "Sources/SkyBridgeBenchmarkSupport/NetworkLoopbackLifecycle.swift"
  "Sources/SkyBridgeBenchmarkSupport/TimedEvent.swift"
  "Sources/SkyBridgeBenchmarkSupport/ConnectionLifecycle.swift"
  "Sources/SkyBridgeBenchmarkSupport/AcceptedConnectionMailbox.swift"
  "Sources/SkyBridgeBenchmarkSupport/ListenerLifecycle.swift"
  "Sources/SkyBridgeBenchmarkSupport/BenchmarkHandshakeKEMIdentityStore.swift"
)
BENCHMARK_KEM_CONSUMERS=(
  "Sources/BaselineBenchRunner/main.swift"
  "Sources/HandshakeBenchRunner/main.swift"
  "Tests/SkyBridgeBenchTests/HandshakeBenchmarkTests.swift"
  "Tests/SkyBridgeCoreTests/HandshakeBenchmarkTests.swift"
  "Tests/SkyBridgeCoreTests/SystemImpactBenchTests.swift"
  "Tests/SkyBridgeCoreTests/HandshakeV2PFSTests.swift"
)

fail() {
  echo "[test-loopback-benchmark-fixture-policy] $1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

require_head_bound_file() {
  local path="$1"
  local index_record
  local index_oid
  local head_oid
  local worktree_oid

  [[ -f "${ROOT_DIR}/${path}" && ! -L "${ROOT_DIR}/${path}" ]] \
    || fail "required fixture must be a regular non-symlink file: ${path}"
  if git -C "${ROOT_DIR}" check-ignore -q -- "${path}"; then
    fail "required fixture is ignored by git: ${path}"
  fi
  git -C "${ROOT_DIR}" ls-files --error-unmatch -- "${path}" >/dev/null 2>&1 \
    || fail "required fixture is not tracked by git: ${path}"
  git -C "${ROOT_DIR}" cat-file -e "HEAD:${path}" 2>/dev/null \
    || fail "required fixture is not present in HEAD: ${path}"

  index_record="$(git -C "${ROOT_DIR}" ls-files --stage -- "${path}")"
  [[ "$(printf '%s\n' "${index_record}" | wc -l | tr -d ' ')" == "1" ]] \
    || fail "required fixture has an ambiguous index entry: ${path}"
  [[ "$(awk '{ print $3 }' <<<"${index_record}")" == "0" ]] \
    || fail "required fixture has an unresolved index stage: ${path}"
  index_oid="$(awk '{ print $2 }' <<<"${index_record}")"
  head_oid="$(git -C "${ROOT_DIR}" rev-parse "HEAD:${path}")"
  worktree_oid="$(git -C "${ROOT_DIR}" hash-object -- "${ROOT_DIR}/${path}")"
  [[ "${index_oid}" == "${head_oid}" && "${worktree_oid}" == "${head_oid}" ]] \
    || fail "required fixture differs across HEAD, index, and worktree: ${path}"
}

require_sha256() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "${ROOT_DIR}/${path}" | awk '{ print $1 }')"
  [[ "${actual}" == "${expected}" ]] \
    || fail "${path} SHA-256 mismatch: expected ${expected}, got ${actual}"
}

require_command git
require_command openssl
require_command shasum

require_head_bound_file "${CERTIFICATE_PATH}"
require_head_bound_file "${PRIVATE_KEY_PATH}"
for support_file in "${BENCHMARK_SUPPORT_FILES[@]}"; do
  require_head_bound_file "${support_file}"
done
require_sha256 "${CERTIFICATE_PATH}" "${CERTIFICATE_SHA256}"
require_sha256 "${PRIVATE_KEY_PATH}" "${PRIVATE_KEY_SHA256}"

certificate_text="$(
  openssl x509 \
    -inform DER \
    -in "${ROOT_DIR}/${CERTIFICATE_PATH}" \
    -noout \
    -subject \
    -issuer \
    -nameopt RFC2253 \
    -text
)" || fail "failed to inspect loopback benchmark certificate"

grep -Fq "subject=CN=localhost" <<<"${certificate_text}" \
  || fail "loopback certificate subject must be exactly CN=localhost"
grep -Fq "issuer=CN=localhost" <<<"${certificate_text}" \
  || fail "loopback certificate must be self-issued"
grep -Fq "ASN1 OID: prime256v1" <<<"${certificate_text}" \
  || fail "loopback certificate must use P-256"
grep -Fq "DNS:localhost, IP Address:127.0.0.1" <<<"${certificate_text}" \
  || fail "loopback certificate SAN must bind localhost and 127.0.0.1"
grep -Fq "X509v3 Basic Constraints: critical" <<<"${certificate_text}" \
  || fail "loopback certificate basic constraints must be critical"
grep -Fq "CA:FALSE" <<<"${certificate_text}" \
  || fail "loopback certificate must be a leaf, not a CA"
grep -Fq "X509v3 Key Usage: critical" <<<"${certificate_text}" \
  || fail "loopback certificate key usage must be critical"
grep -Fq "Digital Signature" <<<"${certificate_text}" \
  || fail "loopback certificate must allow digital signatures"
grep -Fq "TLS Web Server Authentication" <<<"${certificate_text}" \
  || fail "loopback certificate must have the serverAuth extended key usage"

openssl x509 \
  -inform DER \
  -in "${ROOT_DIR}/${CERTIFICATE_PATH}" \
  -checkend 31536000 \
  -noout >/dev/null \
  || fail "loopback certificate must retain at least one year of validity"

[[ "$(wc -c <"${ROOT_DIR}/${PRIVATE_KEY_PATH}" | tr -d ' ')" == "97" ]] \
  || fail "loopback private key must use the 97-byte P-256 X9.63 external representation"
[[ "$(od -An -tx1 -N1 "${ROOT_DIR}/${PRIVATE_KEY_PATH}" | tr -d '[:space:]')" == "04" ]] \
  || fail "loopback private key must start with an uncompressed P-256 public point"

for source_path in \
  "Sources/BaselineBenchRunner/main.swift" \
  "Tests/SkyBridgeBenchTests/BaselineLoopbackBenchTests.swift"; do
  source="$(<"${ROOT_DIR}/${source_path}")"
  grep -Fq "SecIdentityCreate(nil, certificate, privateKey)" <<<"${source}" \
    || fail "${source_path} must construct the loopback identity in memory"
  grep -Fq "complete(actualCertificateDER == expectedCertificateDER)" <<<"${source}" \
    || fail "${source_path} must pin the exact loopback leaf certificate"
  if grep -Eq 'SecPKCS12Import|SecItemAdd|complete\(true\)' <<<"${source}"; then
    fail "${source_path} contains a forbidden Keychain import or unconditional trust path"
  fi
done

package_source="$(<"${ROOT_DIR}/Package.swift")"
package_head_source="$(git -C "${ROOT_DIR}" show HEAD:Package.swift)"
grep -Fq 'name: "SkyBridgeBenchmarkSupport"' <<<"${package_source}" \
  || fail "Package.swift must isolate loopback lifecycle code in SkyBridgeBenchmarkSupport"
grep -Fq 'name: "SkyBridgeBenchmarkSupport"' <<<"${package_head_source}" \
  || fail "HEAD Package.swift must contain SkyBridgeBenchmarkSupport"
for consumer_path in \
  "Sources/BaselineBenchRunner/main.swift" \
  "Tests/SkyBridgeBenchTests/BaselineLoopbackBenchTests.swift"; do
  consumer_source="$(<"${ROOT_DIR}/${consumer_path}")"
  grep -Fq "import SkyBridgeBenchmarkSupport" <<<"${consumer_source}" \
    || fail "${consumer_path} must import SkyBridgeBenchmarkSupport"
done

for consumer_path in "${BENCHMARK_KEM_CONSUMERS[@]}"; do
  consumer_source="$(<"${ROOT_DIR}/${consumer_path}")"
  consumer_head_source="$(git -C "${ROOT_DIR}" show "HEAD:${consumer_path}")"
  for source_variant in "${consumer_source}" "${consumer_head_source}"; do
    grep -Fq "import SkyBridgeBenchmarkSupport" <<<"${source_variant}" \
      || fail "${consumer_path} must import committed SkyBridgeBenchmarkSupport"
    grep -Fq "BenchmarkHandshakeKEMIdentityStore" <<<"${source_variant}" \
      || fail "${consumer_path} must use the committed benchmark-local KEM identity store"
    if grep -Eq 'DeviceIdentityKeyManager\.shared|getKEMPublicKey\(' <<<"${source_variant}"; then
      fail "${consumer_path} must not use the process-wide device KEM identity store"
    fi
  done
done

kem_store_source="$(<"${ROOT_DIR}/Sources/SkyBridgeBenchmarkSupport/BenchmarkHandshakeKEMIdentityStore.swift")"
for kem_store_contract in \
  "KEMIdentityKeyLengthContract.resolve" \
  "privateKey: SecureBytes" \
  "ObjectIdentifier(type(of: provider))"; do
  grep -Fq "${kem_store_contract}" <<<"${kem_store_source}" \
    || fail "benchmark KEM identity store is missing required contract: ${kem_store_contract}"
done
if grep -Eq 'DeviceIdentityKeyManager\.shared|String\(reflecting:|@unchecked Sendable' <<<"${kem_store_source}"; then
  fail "benchmark KEM identity store contains a forbidden global-state or unsafe type-binding pattern"
fi
runner_source="$(<"${ROOT_DIR}/Sources/BaselineBenchRunner/main.swift")"
for runner_contract in \
  "private static func parseProtocolFilter(_ value: String?) throws" \
  "try validateTimingSamples(samples, config: config)" \
  "baseline evidence count mismatch"; do
  grep -Fq "${runner_contract}" <<<"${runner_source}" \
    || fail "BaselineBenchRunner is missing fail-closed evidence contract: ${runner_contract}"
done
if grep -Eq 'Skipping SkyBridge|normalized\.contains\(' <<<"${runner_source}"; then
  fail "BaselineBenchRunner contains a silent provider skip or substring protocol filter"
fi

support_source="$(for support_file in "${BENCHMARK_SUPPORT_FILES[@]}"; do printf '%s\n' "$(<"${ROOT_DIR}/${support_file}")"; done)"
for required_contract in \
  "received a connection without an active reservation" \
  "kickoffCompleted" \
  "waitForTerminal" \
  "maximumTimeoutSeconds"; do
  grep -Fq "${required_contract}" <<<"${support_source}" \
    || fail "loopback lifecycle support is missing required contract: ${required_contract}"
done
if grep -Eq 'DispatchSemaphore|Task\.detached|@unchecked Sendable|(^|[^[:alnum:]_])Mutex([^[:alnum:]_]|$)|var buffered:' <<<"${support_source}"; then
  fail "loopback lifecycle support contains a forbidden concurrency or buffering pattern"
fi

echo "Loopback benchmark fixture policy passed"
