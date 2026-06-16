#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARGO_MANIFEST="${ROOT_DIR}/rust/Cargo.toml"

cd "${ROOT_DIR}"

cargo test --locked --manifest-path "${CARGO_MANIFEST}" -p skybridge-agent remote_desktop
cargo test --locked --manifest-path "${CARGO_MANIFEST}" -p skybridge-core remote_desktop
cargo test --locked --manifest-path "${CARGO_MANIFEST}" -p skybridge remote_desktop
cargo test --locked --manifest-path "${CARGO_MANIFEST}" -p skybridge capabilities_json_contract_is_machine_readable_without_live_success_claims
cargo test --locked --manifest-path "${CARGO_MANIFEST}" -p skybridge check_coverage_gate_exceeds_required_88_percent
