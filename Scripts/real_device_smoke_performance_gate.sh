#!/usr/bin/env bash

skybridge_smoke_run_cli() {
  local root_dir="${1:?missing root dir}"
  shift

  if [[ -n "${SKYBRIDGE_CLI_BIN:-}" ]]; then
    if [[ ! -x "${SKYBRIDGE_CLI_BIN}" ]]; then
      echo "SKYBRIDGE_CLI_BIN is not executable: ${SKYBRIDGE_CLI_BIN}" >&2
      return 2
    fi
    "${SKYBRIDGE_CLI_BIN}" "$@"
    return
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required to run SkyBridge Rust CLI smoke gates" >&2
    return 2
  fi

  cargo run --quiet --manifest-path "${root_dir}/rust/Cargo.toml" -p skybridge -- "$@"
}

skybridge_smoke_check_performance_gate() {
  local root_dir="${1:?missing root dir}"
  local kind="${2:?missing performance kind}"
  local artifact_dir="${3:?missing artifact dir}"
  shift 3

  if [[ ! -d "${artifact_dir}" ]]; then
    echo "real-device smoke artifact directory does not exist: ${artifact_dir}" >&2
    return 2
  fi

  skybridge_smoke_run_cli "${root_dir}" check performance \
    --kind "${kind}" \
    --artifact-dir "${artifact_dir}" \
    "$@"
}
