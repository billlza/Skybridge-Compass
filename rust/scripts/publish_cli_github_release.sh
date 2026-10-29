#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"
REPOSITORY=""
TAG_NAME=""
EXPECTED_SOURCE_SHA=""
ASSETS_DIR=""
VERSION=""
RUST_TOOLCHAIN=""
SOURCE_DATE_EPOCH=""
WORKFLOW_RUN_ID=""
WORKFLOW_RUN_ATTEMPT=""
HANDOFF_ARTIFACT_ID=""
HANDOFF_ARTIFACT_DIGEST=""
PROOF_PATH=""

usage() {
  cat <<'EOF'
Usage: publish_cli_github_release.sh \
  --repository <owner/repo> --tag <skybridge-cli-vX.Y.Z> \
  --expected-source-sha <40-hex> --assets-dir <path> \
  --version <X.Y.Z> --rust-toolchain <X.Y.Z> \
  --source-date-epoch <epoch> --workflow-run-id <id> \
  --workflow-run-attempt <attempt> --handoff-artifact-id <id> \
  --handoff-artifact-digest <sha256> --proof-path <path>

Creates one complete draft, verifies every remote byte, publishes once, and
verifies GitHub's immutable release and per-asset attestations. Existing
published releases are accepted only as exact immutable idempotent recovery.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) REPOSITORY="${2:-}"; shift 2 ;;
    --tag) TAG_NAME="${2:-}"; shift 2 ;;
    --expected-source-sha) EXPECTED_SOURCE_SHA="${2:-}"; shift 2 ;;
    --assets-dir) ASSETS_DIR="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --rust-toolchain) RUST_TOOLCHAIN="${2:-}"; shift 2 ;;
    --source-date-epoch) SOURCE_DATE_EPOCH="${2:-}"; shift 2 ;;
    --workflow-run-id) WORKFLOW_RUN_ID="${2:-}"; shift 2 ;;
    --workflow-run-attempt) WORKFLOW_RUN_ATTEMPT="${2:-}"; shift 2 ;;
    --handoff-artifact-id) HANDOFF_ARTIFACT_ID="${2:-}"; shift 2 ;;
    --handoff-artifact-digest) HANDOFF_ARTIFACT_DIGEST="${2:-}"; shift 2 ;;
    --proof-path) PROOF_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

fail() {
  echo "[cli-github-release] ERROR: $1" >&2
  exit 1
}

for required in REPOSITORY TAG_NAME EXPECTED_SOURCE_SHA ASSETS_DIR VERSION RUST_TOOLCHAIN SOURCE_DATE_EPOCH WORKFLOW_RUN_ID WORKFLOW_RUN_ATTEMPT HANDOFF_ARTIFACT_ID HANDOFF_ARTIFACT_DIGEST PROOF_PATH; do
  [[ -n "${!required}" ]] || fail "missing required argument: ${required}"
done
: "${GH_TOKEN:?GH_TOKEN is required for GitHub CLI publication}"
command -v gh >/dev/null 2>&1 || fail "gh CLI is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v git >/dev/null 2>&1 || fail "git is required"
command -v cmp >/dev/null 2>&1 || fail "cmp is required"

[[ "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "${REPOSITORY}" != *".."* ]] \
  || fail "invalid repository"
[[ "${VERSION}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]] \
  || fail "invalid CLI version"
[[ "${TAG_NAME}" == "skybridge-cli-v${VERSION}" ]] || fail "tag/version mismatch"
[[ "${EXPECTED_SOURCE_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "invalid expected source SHA"
[[ "${RUST_TOOLCHAIN}" =~ ^1\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || fail "invalid Rust toolchain"
[[ "${SOURCE_DATE_EPOCH}" =~ ^[1-9][0-9]*$ ]] || fail "invalid source date epoch"
[[ "${WORKFLOW_RUN_ID}" =~ ^[1-9][0-9]*$ ]] || fail "invalid workflow run ID"
[[ "${WORKFLOW_RUN_ATTEMPT}" =~ ^[1-9][0-9]*$ ]] || fail "invalid workflow run attempt"
[[ "${HANDOFF_ARTIFACT_ID}" =~ ^[1-9][0-9]*$ ]] || fail "invalid handoff artifact ID"
[[ "${HANDOFF_ARTIFACT_DIGEST}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid handoff artifact digest"
[[ -d "${ASSETS_DIR}" && ! -L "${ASSETS_DIR}" ]] || fail "assets directory is invalid"

python3 "${ROOT_DIR}/scripts/finalize_cli_release_assets.py" verify \
  --assets-dir "${ASSETS_DIR}" \
  --version "${VERSION}" \
  --source-repository "${REPOSITORY}" \
  --source-sha "${EXPECTED_SOURCE_SHA}" \
  --rust-toolchain "${RUST_TOOLCHAIN}" \
  --source-date-epoch "${SOURCE_DATE_EPOCH}"

[[ "$(git -C "${PROJECT_ROOT}" rev-parse --verify HEAD)" == "${EXPECTED_SOURCE_SHA}" ]] \
  || fail "publisher checkout does not match the expected source SHA"
[[ -z "$(git -C "${PROJECT_ROOT}" status --porcelain=v1 --untracked-files=all)" ]] \
  || fail "publisher checkout must be clean"
[[ "$(git -C "${PROJECT_ROOT}" rev-parse "refs/tags/${TAG_NAME}^{commit}")" == "${EXPECTED_SOURCE_SHA}" ]] \
  || fail "release tag does not resolve to the expected source SHA"

verify_remote_tag() {
  [[ "$(gh api "repos/${REPOSITORY}/commits/${TAG_NAME}" --jq '.sha')" == "${EXPECTED_SOURCE_SHA}" ]] \
    || fail "remote release tag does not resolve to the expected source SHA"
}
verify_remote_tag

# The immutable-releases setting is an administration read that the
# workflow's integration token is not allowed to see (HTTP 403). That exact
# refusal is tolerated here — the published release's isImmutable flag is
# asserted after publication either way, which is the enforcing check. Any
# readable answer other than enabled=true still fails closed.
immutable_probe_stderr="$(mktemp "${TMPDIR:-/tmp}/skybridge-immutable-probe.XXXXXX")"
if immutable_enabled="$(
  gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "repos/${REPOSITORY}/immutable-releases" \
    --jq '.enabled' 2>"${immutable_probe_stderr}"
)"; then
  /bin/rm -f "${immutable_probe_stderr}"
  [[ "${immutable_enabled}" == "true" ]] || fail "repository immutable releases must be enabled"
else
  if grep -q "HTTP 403" "${immutable_probe_stderr}"; then
    /bin/rm -f "${immutable_probe_stderr}"
    echo "[cli-github-release] immutable-releases setting is not readable by this token; relying on the post-publish isImmutable assertion"
  else
    cat "${immutable_probe_stderr}" >&2
    /bin/rm -f "${immutable_probe_stderr}"
    fail "unable to read the repository immutable-releases setting"
  fi
fi

asset_names=(
  "skybridge-aarch64-apple-darwin.tar.gz"
  "skybridge-aarch64-unknown-linux-gnu.tar.gz"
  "skybridge-x86_64-unknown-linux-gnu.tar.gz"
  "skybridge-x86_64-pc-windows-msvc.zip"
  "skybridge-cli-${VERSION}.tgz"
  "skybridge.rb"
  "release-manifest.json"
  "SHA256SUMS.txt"
)
asset_paths=()
for name in "${asset_names[@]}"; do
  path="${ASSETS_DIR}/${name}"
  [[ -f "${path}" && ! -L "${path}" ]] || fail "missing exact release asset: ${name}"
  asset_paths+=("${path}")
done

VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-cli-github-release.XXXXXX")"
cleanup() {
  /bin/rm -rf "${VERIFY_ROOT}"
}
trap cleanup EXIT
RELEASE_STATE="${VERIFY_ROOT}/release-state.json"
READBACK_DIR="${VERIFY_ROOT}/readback"
ATTESTATION_JSON="${VERIFY_ROOT}/release-attestation.json"

read_release_state() {
  gh release view "${TAG_NAME}" \
    --repo "${REPOSITORY}" \
    --json tagName,isDraft,isImmutable,assets >"${RELEASE_STATE}"
}

verify_remote_assets() {
  read_release_state
  python3 - "${RELEASE_STATE}" "${VERSION}" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
version = sys.argv[2]
expected_tag = f"skybridge-cli-v{version}"
if state.get("tagName") != expected_tag:
    raise SystemExit("remote GitHub release tag does not match the requested version")
expected = {
    "skybridge-aarch64-apple-darwin.tar.gz",
    "skybridge-aarch64-unknown-linux-gnu.tar.gz",
    "skybridge-x86_64-unknown-linux-gnu.tar.gz",
    "skybridge-x86_64-pc-windows-msvc.zip",
    f"skybridge-cli-{version}.tgz",
    "skybridge.rb",
    "release-manifest.json",
    "SHA256SUMS.txt",
}
names = [asset.get("name") for asset in state.get("assets", [])]
if len(names) != len(set(names)) or set(names) != expected:
    raise SystemExit("remote GitHub release does not contain the exact eight assets")
PY
  /bin/rm -rf "${READBACK_DIR}"
  mkdir -m 0700 "${READBACK_DIR}"
  gh release download "${TAG_NAME}" --repo "${REPOSITORY}" --dir "${READBACK_DIR}"
  python3 "${ROOT_DIR}/scripts/finalize_cli_release_assets.py" verify \
    --assets-dir "${READBACK_DIR}" \
    --version "${VERSION}" \
    --source-repository "${REPOSITORY}" \
    --source-sha "${EXPECTED_SOURCE_SHA}" \
    --rust-toolchain "${RUST_TOOLCHAIN}" \
    --source-date-epoch "${SOURCE_DATE_EPOCH}"
  for name in "${asset_names[@]}"; do
    cmp -- "${ASSETS_DIR}/${name}" "${READBACK_DIR}/${name}" \
      || fail "remote GitHub asset differs from the staged byte sequence: ${name}"
  done
}

release_exists=0
if gh release view "${TAG_NAME}" --repo "${REPOSITORY}" >/dev/null 2>&1; then
  release_exists=1
fi

if [[ "${release_exists}" == "0" ]]; then
  gh release create "${TAG_NAME}" \
    "${asset_paths[@]}" \
    --repo "${REPOSITORY}" \
    --verify-tag \
    --draft \
    --latest=false \
    --title "SkyBridge CLI v${VERSION}" \
    --generate-notes \
    || fail "draft creation or complete asset attachment failed; audit any partial draft before retrying"
fi

read_release_state
state_line="$(python3 - "${RELEASE_STATE}" <<'PY'
import json
import pathlib
import sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(f"{str(state.get('isDraft')).lower()}\t{str(state.get('isImmutable')).lower()}")
PY
)"
IFS=$'\t' read -r is_draft is_immutable <<<"${state_line}"

if [[ "${is_draft}" == "false" ]]; then
  [[ "${is_immutable}" == "true" ]] \
    || fail "an existing published CLI release is not immutable"
  verify_remote_assets
  verify_remote_tag
else
  [[ "${is_draft}" == "true" && "${is_immutable}" == "false" ]] \
    || fail "existing release has an invalid draft/immutability state"
  verify_remote_assets
  verify_remote_tag
  gh release edit "${TAG_NAME}" \
    --repo "${REPOSITORY}" \
    --draft=false \
    --latest=false
fi

verify_remote_assets
verify_remote_tag
read_release_state
python3 - "${RELEASE_STATE}" <<'PY'
import json
import pathlib
import sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if state.get("isDraft") is not False or state.get("isImmutable") is not True:
    raise SystemExit("published CLI release did not become immutable")
PY

verify_attestations() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if gh release verify "${TAG_NAME}" --repo "${REPOSITORY}" --format json >"${ATTESTATION_JSON}" && \
      python3 - "${ATTESTATION_JSON}" "${ASSETS_DIR}" "${REPOSITORY}" "${TAG_NAME}" "${EXPECTED_SOURCE_SHA}" "${VERSION}" <<'PY'
import hashlib
import json
import pathlib
import sys

attestation_path, assets_path, repository, tag, source_sha, version = sys.argv[1:]
value = json.loads(pathlib.Path(attestation_path).read_text(encoding="utf-8"))
statement = value.get("verificationResult", {}).get("statement", {})
if statement.get("predicateType") != "https://in-toto.io/attestation/release/v0.2":
    raise SystemExit("GitHub release attestation has an unexpected predicate type")
predicate = statement.get("predicate", {})
if predicate.get("repository") != repository or predicate.get("tag") != tag:
    raise SystemExit("GitHub release attestation repository or tag mismatch")
expected_purl = f"pkg:github/{repository}@{tag}"
subjects = statement.get("subject")
if not isinstance(subjects, list):
    raise SystemExit("GitHub release attestation has no subject list")
source_subjects = [subject for subject in subjects if subject.get("uri") == expected_purl]
if len(source_subjects) != 1 or source_subjects[0].get("digest", {}).get("sha1") != source_sha:
    raise SystemExit("GitHub release attestation source commit mismatch")
expected_names = {
    "skybridge-aarch64-apple-darwin.tar.gz",
    "skybridge-aarch64-unknown-linux-gnu.tar.gz",
    "skybridge-x86_64-unknown-linux-gnu.tar.gz",
    "skybridge-x86_64-pc-windows-msvc.zip",
    f"skybridge-cli-{version}.tgz",
    "skybridge.rb",
    "release-manifest.json",
    "SHA256SUMS.txt",
}
asset_subjects = [subject for subject in subjects if "name" in subject]
actual_names = [subject.get("name") for subject in asset_subjects]
if len(actual_names) != len(set(actual_names)) or set(actual_names) != expected_names:
    raise SystemExit("GitHub release attestation does not cover the exact eight assets")
assets_dir = pathlib.Path(assets_path)
for subject in asset_subjects:
    name = subject["name"]
    actual = hashlib.sha256((assets_dir / name).read_bytes()).hexdigest()
    if subject.get("digest", {}).get("sha256") != actual:
        raise SystemExit(f"GitHub release attestation digest mismatch: {name}")
PY
    then
      if {
      local asset
      local all_assets_verified=1
      for asset in "${asset_paths[@]}"; do
        if ! gh release verify-asset "${TAG_NAME}" "${asset}" --repo "${REPOSITORY}"; then
          all_assets_verified=0
          break
        fi
      done
      [[ "${all_assets_verified}" == "1" ]]
      }; then
      return 0
      fi
    fi
    if [[ "${attempt}" != "6" ]]; then
      sleep 5
    fi
  done
  fail "release or asset attestations did not verify within the bounded retry window"
}
verify_attestations

mkdir -p "$(dirname "${PROOF_PATH}")"
python3 - \
  "${ASSETS_DIR}/release-manifest.json" \
  "${PROOF_PATH}" \
  "${REPOSITORY}" \
  "${TAG_NAME}" \
  "${EXPECTED_SOURCE_SHA}" \
  "${WORKFLOW_RUN_ID}" \
  "${WORKFLOW_RUN_ATTEMPT}" \
  "${HANDOFF_ARTIFACT_ID}" \
  "${HANDOFF_ARTIFACT_DIGEST}" <<'PY'
import json
import hashlib
import os
import pathlib
import sys
import tempfile

(
    manifest_path,
    proof_path,
    repository,
    tag,
    source_sha,
    workflow_run_id,
    workflow_run_attempt,
    handoff_artifact_id,
    handoff_artifact_digest,
) = sys.argv[1:]
assets_dir = pathlib.Path(manifest_path).parent
manifest = json.loads(pathlib.Path(manifest_path).read_text(encoding="utf-8"))
asset_names = [entry["name"] for entry in manifest["assets"]] + [
    "release-manifest.json",
    "SHA256SUMS.txt",
]
assets = []
for name in asset_names:
    path = assets_dir / name
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    assets.append({"name": name, "sha256": digest, "size_bytes": path.stat().st_size})
proof = {
    "schema_version": 1,
    "profile": "skybridge-cli-github-release-proof",
    "status": "published-immutable-and-verified",
    "repository": repository,
    "tag": tag,
    "source_sha": source_sha,
    "workflow_run_id": int(workflow_run_id),
    "workflow_run_attempt": int(workflow_run_attempt),
    "handoff_artifact_id": int(handoff_artifact_id),
    "handoff_artifact_digest": handoff_artifact_digest,
    "immutable": True,
    "assets": assets,
}
destination = pathlib.Path(proof_path)
destination.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(proof, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, destination)
except BaseException:
    try:
        os.close(fd)
    except OSError:
        pass
    pathlib.Path(temporary).unlink(missing_ok=True)
    raise
PY

echo "[cli-github-release] published and verified ${REPOSITORY}@${TAG_NAME}"
