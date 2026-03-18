#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS_DIR=""
VERSION=""
PYTHON_BIN="${PYTHON_BIN:-python3}"

usage() {
  cat <<'EOF'
Usage: assemble_release_assets.sh --assets-dir <dir> --version <version>

Validates the expected release archives, writes SHA256SUMS.txt and
release-manifest.json, and renders the Homebrew formula into the assets dir.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --assets-dir)
      ASSETS_DIR="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
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

if [[ -z "${ASSETS_DIR}" || -z "${VERSION}" ]]; then
  usage >&2
  exit 1
fi

mkdir -p "${ASSETS_DIR}"

"${PYTHON_BIN}" - "${ASSETS_DIR}" "${VERSION}" <<'PY'
import hashlib
import json
import pathlib
import sys
import time

assets_dir = pathlib.Path(sys.argv[1])
version = sys.argv[2]
expected = [
    ("skybridge-aarch64-apple-darwin.tar.gz", "darwin", "arm64"),
    ("skybridge-x86_64-apple-darwin.tar.gz", "darwin", "x64"),
    ("skybridge-aarch64-unknown-linux-gnu.tar.gz", "linux", "arm64"),
    ("skybridge-x86_64-unknown-linux-gnu.tar.gz", "linux", "x64"),
    ("skybridge-x86_64-pc-windows-msvc.zip", "windows", "x64"),
]

missing = [name for name, _, _ in expected if not (assets_dir / name).is_file()]
if missing:
    raise SystemExit(f"missing release archives: {', '.join(missing)}")

entries = []
for name, os_name, arch in expected:
    path = assets_dir / name
    sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
    entries.append(
        {
            "name": name,
            "os": os_name,
            "arch": arch,
            "size": path.stat().st_size,
            "sha256": sha256,
        }
    )

checksum_lines = [f"{entry['sha256']}  {entry['name']}" for entry in entries]
(assets_dir / "SHA256SUMS.txt").write_text("\n".join(checksum_lines) + "\n", encoding="utf-8")

manifest = {
    "version": version,
    "release_tag": f"skybridge-cli-v{version}",
    "generated_at_epoch": int(time.time()),
    "assets": entries,
}
(assets_dir / "release-manifest.json").write_text(
    json.dumps(manifest, indent=2) + "\n",
    encoding="utf-8",
)
PY

eval "$(
  "${PYTHON_BIN}" - "${ASSETS_DIR}/release-manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
by_name = {entry["name"]: entry["sha256"] for entry in manifest["assets"]}
print(f'SKYBRIDGE_DARWIN_ARM64_SHA256={by_name["skybridge-aarch64-apple-darwin.tar.gz"]}')
print(f'SKYBRIDGE_DARWIN_AMD64_SHA256={by_name["skybridge-x86_64-apple-darwin.tar.gz"]}')
PY
)"

SKYBRIDGE_VERSION="${VERSION}" \
SKYBRIDGE_DARWIN_ARM64_SHA256="${SKYBRIDGE_DARWIN_ARM64_SHA256}" \
SKYBRIDGE_DARWIN_AMD64_SHA256="${SKYBRIDGE_DARWIN_AMD64_SHA256}" \
"${ROOT_DIR}/scripts/render_homebrew_formula.sh" "${ASSETS_DIR}/skybridge.rb"

echo "assembled release assets in ${ASSETS_DIR}"
