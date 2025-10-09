#!/usr/bin/env bash
set -euo pipefail

CMD=${1:-tasks}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PROJECT_DIR="$ROOT_DIR"

pushd "$PROJECT_DIR" >/dev/null
"$ROOT_DIR/scripts/codex-env-check.sh" || true

# 注入 aapt2 覆盖（优先环境变量，再回退 local.properties），跨平台
sdk_dir=""
if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT" ]]; then
  sdk_dir="$ANDROID_SDK_ROOT"
elif [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME" ]]; then
  sdk_dir="$ANDROID_HOME"
elif [[ -f local.properties ]]; then
  sdk_dir=$(grep '^sdk.dir=' local.properties | cut -d'=' -f2- || true)
fi
EXTRA_PROPS=()
if [[ -n "$sdk_dir" && -x "$sdk_dir/build-tools/35.0.0/aapt2" ]]; then
  EXTRA_PROPS+=( "-Dandroid.aapt2FromMavenOverride=$sdk_dir/build-tools/35.0.0/aapt2" )
fi

if [[ -x ./gradlew ]]; then
  ./gradlew "${EXTRA_PROPS[@]}" --offline --stacktrace --console=plain ${CMD}
else
  gradle "${EXTRA_PROPS[@]}" --offline --stacktrace --console=plain ${CMD}
fi
popd >/dev/null
