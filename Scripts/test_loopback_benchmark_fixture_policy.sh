#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTIFICATE_PATH="Tests/Fixtures/loopback_test_server_certificate.der"
PRIVATE_KEY_PATH="Tests/Fixtures/loopback_test_server_private_key.x963"
CERTIFICATE_SHA256="b745f9d72a335f1c92444209ecb052dba0dd1f11a534b2a8dbe5ab95b5c35f24"
PRIVATE_KEY_SHA256="1e3552f72f70f7fd0ae2c23ee126f3895efe989af22485ebc784a504ebdfbb87"

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

echo "Loopback benchmark fixture policy passed"
