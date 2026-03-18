#!/usr/bin/env bash
set -euo pipefail

FORMULA_FILE=""
TAP_REPO=""
FORMULA_PATH="Formula/skybridge.rb"
TARGET_BRANCH="main"

usage() {
  cat <<'EOF'
Usage: publish_homebrew_formula.sh --tap-repo <owner/repo> --formula-file <path> [--formula-path Formula/skybridge.rb] [--branch main]

Pushes the rendered Homebrew formula into a tap repository.
Requires HOMEBREW_TAP_GITHUB_TOKEN in the environment.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tap-repo)
      TAP_REPO="${2:-}"
      shift 2
      ;;
    --formula-file)
      FORMULA_FILE="${2:-}"
      shift 2
      ;;
    --formula-path)
      FORMULA_PATH="${2:-}"
      shift 2
      ;;
    --branch)
      TARGET_BRANCH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${TAP_REPO}" || -z "${FORMULA_FILE}" ]]; then
  usage >&2
  exit 1
fi

: "${HOMEBREW_TAP_GITHUB_TOKEN:?set HOMEBREW_TAP_GITHUB_TOKEN}"

if [[ ! -f "${FORMULA_FILE}" ]]; then
  echo "formula file not found: ${FORMULA_FILE}" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

git clone --depth 1 --branch "${TARGET_BRANCH}" \
  "https://x-access-token:${HOMEBREW_TAP_GITHUB_TOKEN}@github.com/${TAP_REPO}.git" \
  "${TMP_DIR}/tap"

mkdir -p "${TMP_DIR}/tap/$(dirname "${FORMULA_PATH}")"
cp "${FORMULA_FILE}" "${TMP_DIR}/tap/${FORMULA_PATH}"

pushd "${TMP_DIR}/tap" >/dev/null
if git diff --quiet -- "${FORMULA_PATH}"; then
  echo "Homebrew formula already up to date"
  popd >/dev/null
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "${FORMULA_PATH}"
git commit -m "Update Skybridge formula"
git push origin "${TARGET_BRANCH}"
popd >/dev/null

echo "published Homebrew formula to ${TAP_REPO}:${FORMULA_PATH}"
