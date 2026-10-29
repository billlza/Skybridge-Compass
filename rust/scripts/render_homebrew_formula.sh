#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_PATH="${ROOT_DIR}/packaging/homebrew/skybridge.rb.template"
OUTPUT_PATH="${1:-${ROOT_DIR}/packaging/homebrew/skybridge.rb}"

: "${SKYBRIDGE_VERSION:?set SKYBRIDGE_VERSION}"
: "${SKYBRIDGE_DARWIN_ARM64_SHA256:?set SKYBRIDGE_DARWIN_ARM64_SHA256}"
: "${SKYBRIDGE_RELEASE_BASE_URL:?set SKYBRIDGE_RELEASE_BASE_URL}"

python3 - \
  "${TEMPLATE_PATH}" "${OUTPUT_PATH}" "${SKYBRIDGE_VERSION}" \
  "${SKYBRIDGE_DARWIN_ARM64_SHA256}" "${SKYBRIDGE_RELEASE_BASE_URL}" <<'PY'
import os
import pathlib
import re
import tempfile
import sys

template_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
version = sys.argv[3]
digest = sys.argv[4]
base_url = sys.argv[5]
version_pattern = (
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)
if re.fullmatch(version_pattern, version) is None:
    raise SystemExit("invalid SkyBridge CLI version")
if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit("invalid Darwin archive SHA-256")
expected_suffix = f"/releases/download/skybridge-cli-v{version}"
if (
    re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/skybridge-cli-v[^/]+", base_url)
    is None
    or ".." in base_url
    or not base_url.endswith(expected_suffix)
):
    raise SystemExit("invalid GitHub release base URL")
if output_path.exists() or output_path.is_symlink():
    raise SystemExit(f"refusing to replace an existing formula: {output_path}")
if not output_path.parent.is_dir() or output_path.parent.is_symlink():
    raise SystemExit("formula output parent must be a real directory")

template = template_path.read_text(encoding="utf-8")
expected_placeholders = {
    "__VERSION__": version,
    "__BASE_URL__": base_url,
    "__DARWIN_ARM64_SHA256__": digest,
}
for placeholder in expected_placeholders:
    if template.count(placeholder) != 1:
        raise SystemExit(f"formula template must contain exactly one {placeholder}")
rendered = template
for placeholder, value in expected_placeholders.items():
    rendered = rendered.replace(placeholder, value)
if "__" in rendered:
    raise SystemExit("formula template contains unresolved placeholders")

descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output_path.name}.", dir=output_path.parent)
temporary_path = pathlib.Path(temporary_name)
try:
    os.fchmod(descriptor, 0o644)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(rendered)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_path, output_path)
except BaseException:
    try:
        os.close(descriptor)
    except OSError:
        pass
    temporary_path.unlink(missing_ok=True)
    raise
PY

echo "rendered Homebrew formula to ${OUTPUT_PATH}"
