#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMULA_FILE=""
DARWIN_ARCHIVE=""
TAP_REPO=""
FORMULA_PATH="Formula/skybridge.rb"
TARGET_BRANCH="main"
VERSION=""
SOURCE_REPOSITORY=""
SOURCE_SHA=""
WORKFLOW_RUN_ID=""
WORKFLOW_RUN_ATTEMPT=""
HANDOFF_ARTIFACT_ID=""
HANDOFF_ARTIFACT_DIGEST=""
PROOF_PATH=""

usage() {
  cat <<'EOF'
Usage: publish_homebrew_formula.sh \
  --tap-repo <owner/repo> --formula-file <path> --darwin-archive <path> \
  --formula-path <Formula/skybridge.rb> --branch <branch> \
  --version <X.Y.Z> --source-repository <owner/repo> \
  --source-sha <40-hex> --workflow-run-id <id> \
  --workflow-run-attempt <attempt> --handoff-artifact-id <id> \
  --handoff-artifact-digest <sha256> --proof-path <path>

Publishes one reviewed formula without embedding credentials in Git URLs.
An existing identical remote formula is accepted as idempotent recovery.
EOF
}

fail() {
  echo "[cli-homebrew-release] ERROR: $1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tap-repo) TAP_REPO="${2:-}"; shift 2 ;;
    --formula-file) FORMULA_FILE="${2:-}"; shift 2 ;;
    --darwin-archive) DARWIN_ARCHIVE="${2:-}"; shift 2 ;;
    --formula-path) FORMULA_PATH="${2:-}"; shift 2 ;;
    --branch) TARGET_BRANCH="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --source-repository) SOURCE_REPOSITORY="${2:-}"; shift 2 ;;
    --source-sha) SOURCE_SHA="${2:-}"; shift 2 ;;
    --workflow-run-id) WORKFLOW_RUN_ID="${2:-}"; shift 2 ;;
    --workflow-run-attempt) WORKFLOW_RUN_ATTEMPT="${2:-}"; shift 2 ;;
    --handoff-artifact-id) HANDOFF_ARTIFACT_ID="${2:-}"; shift 2 ;;
    --handoff-artifact-digest) HANDOFF_ARTIFACT_DIGEST="${2:-}"; shift 2 ;;
    --proof-path) PROOF_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

for required in TAP_REPO FORMULA_FILE DARWIN_ARCHIVE FORMULA_PATH TARGET_BRANCH VERSION SOURCE_REPOSITORY SOURCE_SHA WORKFLOW_RUN_ID WORKFLOW_RUN_ATTEMPT HANDOFF_ARTIFACT_ID HANDOFF_ARTIFACT_DIGEST PROOF_PATH; do
  [[ -n "${!required}" ]] || fail "missing required argument: ${required}"
done
: "${HOMEBREW_TAP_GITHUB_TOKEN:?HOMEBREW_TAP_GITHUB_TOKEN is required}"
command -v git >/dev/null 2>&1 || fail "git is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v cmp >/dev/null 2>&1 || fail "cmp is required"

[[ "${TAP_REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "${TAP_REPO}" != *".."* ]] \
  || fail "invalid tap repository"
[[ "${SOURCE_REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "${SOURCE_REPOSITORY}" != *".."* ]] \
  || fail "invalid source repository"
[[ "${TARGET_BRANCH}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "${TARGET_BRANCH}" != *".."* && "${TARGET_BRANCH}" != */ ]] \
  || fail "invalid tap branch"
git check-ref-format --branch "${TARGET_BRANCH}" >/dev/null || fail "invalid tap branch"
[[ "${FORMULA_PATH}" =~ ^Formula/[A-Za-z0-9_.+-]+\.rb$ && "${FORMULA_PATH}" != *".."* ]] \
  || fail "formula path must be one regular file directly below Formula/"
[[ "${VERSION}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] \
  || fail "invalid CLI version"
[[ "${SOURCE_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "invalid source SHA"
[[ "${WORKFLOW_RUN_ID}" =~ ^[1-9][0-9]*$ ]] || fail "invalid workflow run ID"
[[ "${WORKFLOW_RUN_ATTEMPT}" =~ ^[1-9][0-9]*$ ]] || fail "invalid workflow run attempt"
[[ "${HANDOFF_ARTIFACT_ID}" =~ ^[1-9][0-9]*$ ]] || fail "invalid handoff artifact ID"
[[ "${HANDOFF_ARTIFACT_DIGEST}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid handoff artifact digest"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-cli-homebrew.XXXXXX")"
cleanup() {
  /bin/rm -rf "${TMP_DIR}"
}
trap cleanup EXIT
DARWIN_SHA256="$(python3 - "${FORMULA_FILE}" "${DARWIN_ARCHIVE}" <<'PY'
import hashlib
import pathlib
import stat
import sys

formula, archive = map(pathlib.Path, sys.argv[1:])
for path, maximum in ((formula, 1024 * 1024), (archive, 512 * 1024 * 1024)):
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise SystemExit(f"release input must be one non-linked regular file: {path}")
    if metadata.st_size <= 0 or metadata.st_size > maximum:
        raise SystemExit(f"release input size is outside the contract: {path}")
digest = hashlib.sha256()
with archive.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
)"
SKYBRIDGE_VERSION="${VERSION}" \
SKYBRIDGE_DARWIN_ARM64_SHA256="${DARWIN_SHA256}" \
SKYBRIDGE_RELEASE_BASE_URL="https://github.com/${SOURCE_REPOSITORY}/releases/download/skybridge-cli-v${VERSION}" \
  "${ROOT_DIR}/scripts/render_homebrew_formula.sh" "${TMP_DIR}/expected-skybridge.rb"
cmp -- "${FORMULA_FILE}" "${TMP_DIR}/expected-skybridge.rb" \
  || fail "formula bytes do not match the reviewed template and Darwin archive"

ASKPASS_PATH="${TMP_DIR}/git-askpass.sh"
cat >"${ASKPASS_PATH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) printf '%s\n' "${HOMEBREW_TAP_GITHUB_TOKEN:?}" ;;
  *) exit 1 ;;
esac
EOF
chmod 0700 "${ASKPASS_PATH}"

export GIT_ASKPASS="${ASKPASS_PATH}"
export GIT_TERMINAL_PROMPT=0
PLAIN_REMOTE="https://github.com/${TAP_REPO}.git"
git clone --depth 1 --single-branch --branch "${TARGET_BRANCH}" \
  "${PLAIN_REMOTE}" "${TMP_DIR}/tap"
[[ "$(git -C "${TMP_DIR}/tap" remote get-url origin)" == "${PLAIN_REMOTE}" ]] \
  || fail "tap clone persisted an unexpected remote URL"

DESTINATION="${TMP_DIR}/tap/${FORMULA_PATH}"
python3 - "${TMP_DIR}/tap" "${FORMULA_PATH}" <<'PY'
import os
import pathlib
import stat
import sys

checkout = pathlib.Path(sys.argv[1])
relative = pathlib.PurePosixPath(sys.argv[2])
checkout_metadata = checkout.lstat()
if stat.S_ISLNK(checkout_metadata.st_mode) or not stat.S_ISDIR(checkout_metadata.st_mode):
    raise SystemExit("tap checkout must be a real directory")
parent = checkout
for component in relative.parts[:-1]:
    parent = parent / component
    try:
        metadata = parent.lstat()
    except FileNotFoundError:
        os.mkdir(parent, 0o755)
        metadata = parent.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit("tap formula path contains a linked or non-directory component")
destination = checkout / pathlib.Path(*relative.parts)
if destination.exists() or destination.is_symlink():
    metadata = destination.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise SystemExit("existing tap formula is not a regular file")
PY
python3 - "${FORMULA_FILE}" "${DESTINATION}" "${VERSION}" <<'PY'
import pathlib
import re
import sys

candidate = pathlib.Path(sys.argv[1])
existing = pathlib.Path(sys.argv[2])
requested_version = sys.argv[3]


def parse(value: str) -> tuple[tuple[int, int, int], tuple[str, ...] | None]:
    match = re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?", value)
    if match is None:
        raise SystemExit(f"invalid semantic version in tap formula: {value!r}")
    prerelease = tuple(match.group(4).split(".")) if match.group(4) else None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3))), prerelease


def compare_identifiers(left: tuple[str, ...], right: tuple[str, ...]) -> int:
    for left_item, right_item in zip(left, right):
        if left_item == right_item:
            continue
        left_numeric = left_item.isdigit()
        right_numeric = right_item.isdigit()
        if left_numeric and right_numeric:
            return (int(left_item) > int(right_item)) - (int(left_item) < int(right_item))
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return (left_item > right_item) - (left_item < right_item)
    return (len(left) > len(right)) - (len(left) < len(right))


def compare(left: str, right: str) -> int:
    left_core, left_pre = parse(left)
    right_core, right_pre = parse(right)
    if left_core != right_core:
        return (left_core > right_core) - (left_core < right_core)
    if left_pre is None or right_pre is None:
        if left_pre is None and right_pre is None:
            return 0
        return 1 if left_pre is None else -1
    return compare_identifiers(left_pre, right_pre)


if existing.exists():
    if existing.is_symlink() or not existing.is_file():
        raise SystemExit("existing tap formula is not a regular file")
    text = existing.read_text(encoding="utf-8")
    matches = re.findall(r'^\s*version "([^"]+)"\s*$', text, flags=re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit("existing tap formula must declare exactly one version")
    relation = compare(matches[0], requested_version)
    if relation > 0:
        raise SystemExit("refusing to downgrade the Homebrew tap formula")
    if relation == 0 and existing.read_bytes() != candidate.read_bytes():
        raise SystemExit("same-version Homebrew formula bytes differ; refusing equivocation")
PY
cp -- "${FORMULA_FILE}" "${DESTINATION}"
chmod 0644 "${DESTINATION}"

status="already-current"
if ! git -C "${TMP_DIR}/tap" diff --quiet -- "${FORMULA_PATH}" || \
   [[ -n "$(git -C "${TMP_DIR}/tap" status --short --untracked-files=all -- "${FORMULA_PATH}")" ]]; then
  git -C "${TMP_DIR}/tap" add -- "${FORMULA_PATH}"
  git -C "${TMP_DIR}/tap" \
    -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -m "Update SkyBridge CLI formula to v${VERSION}"
  if git -C "${TMP_DIR}/tap" push origin "HEAD:refs/heads/${TARGET_BRANCH}"; then
    status="published-new"
  else
    git -C "${TMP_DIR}/tap" fetch --depth 1 origin "refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}"
    git -C "${TMP_DIR}/tap" show "refs/remotes/origin/${TARGET_BRANCH}:${FORMULA_PATH}" \
      >"${TMP_DIR}/remote-formula.rb" \
      || fail "tap push failed and the remote formula is unavailable"
    cmp -- "${FORMULA_FILE}" "${TMP_DIR}/remote-formula.rb" \
      || fail "tap push conflicted with different remote formula bytes"
    status="published-concurrently-exact"
  fi
fi

git -C "${TMP_DIR}/tap" fetch --depth 1 origin "refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}"
git -C "${TMP_DIR}/tap" show "refs/remotes/origin/${TARGET_BRANCH}:${FORMULA_PATH}" \
  >"${TMP_DIR}/verified-formula.rb"
cmp -- "${FORMULA_FILE}" "${TMP_DIR}/verified-formula.rb" \
  || fail "remote formula differs after publication"
remote_commit="$(git -C "${TMP_DIR}/tap" rev-parse "refs/remotes/origin/${TARGET_BRANCH}^{commit}")"

mkdir -p "$(dirname "${PROOF_PATH}")"
python3 - \
  "${FORMULA_FILE}" "${PROOF_PATH}" "${status}" "${TAP_REPO}" \
  "${TARGET_BRANCH}" "${FORMULA_PATH}" "${VERSION}" "${SOURCE_REPOSITORY}" \
  "${SOURCE_SHA}" "${WORKFLOW_RUN_ID}" "${WORKFLOW_RUN_ATTEMPT}" \
  "${HANDOFF_ARTIFACT_ID}" "${HANDOFF_ARTIFACT_DIGEST}" "${remote_commit}" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import tempfile

(
    formula_file,
    proof_path,
    status,
    tap_repository,
    branch,
    formula_path,
    version,
    source_repository,
    source_sha,
    workflow_run_id,
    workflow_run_attempt,
    handoff_artifact_id,
    handoff_artifact_digest,
    remote_commit,
) = sys.argv[1:]
formula = pathlib.Path(formula_file)
proof = {
    "schema_version": 1,
    "profile": "skybridge-cli-homebrew-release-proof",
    "status": status,
    "tap_repository": tap_repository,
    "branch": branch,
    "formula_path": formula_path,
    "version": version,
    "source_repository": source_repository,
    "source_sha": source_sha,
    "workflow_run_id": int(workflow_run_id),
    "workflow_run_attempt": int(workflow_run_attempt),
    "handoff_artifact_id": int(handoff_artifact_id),
    "handoff_artifact_digest": handoff_artifact_digest,
    "formula_sha256": hashlib.sha256(formula.read_bytes()).hexdigest(),
    "remote_commit": remote_commit,
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

echo "[cli-homebrew-release] ${status}: ${TAP_REPO}:${FORMULA_PATH}@${remote_commit}"
