#!/usr/bin/env bash
set -euo pipefail

log() { echo "[codex-env] $*"; }

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PROJECT_DIR="$ROOT_DIR/YunQiaoSiNan"

pushd "$PROJECT_DIR" >/dev/null

# Java
if command -v java >/dev/null 2>&1; then
  java -version 2>&1 | head -n1 | sed 's/^/[codex-env] /'
else
  log "java 未找到"
fi

# Gradle Wrapper
if [[ -x "./gradlew" ]]; then
  ./gradlew --version || true
else
  log "gradlew 不存在或不可执行"
  if command -v gradle >/dev/null 2>&1; then
    gradle --version || true
  fi
fi

# Android SDK
sdk_dir=""
if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT" ]]; then
  sdk_dir="$ANDROID_SDK_ROOT"
elif [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME" ]]; then
  sdk_dir="$ANDROID_HOME"
elif [[ -f local.properties ]]; then
  sdk_dir=$(grep '^sdk.dir=' local.properties | cut -d'=' -f2- || true)
fi
if [[ -n "$sdk_dir" && -d "$sdk_dir" ]]; then
  log "Android SDK: $sdk_dir"
else
  log "未检测到有效的 Android SDK（优先 ANDROID_SDK_ROOT/ANDROID_HOME，或 local.properties）"
fi

# 离线仓库
if [[ -d "$ROOT_DIR/third_party/m2repository" ]]; then
  log "检测到离线仓库: third_party/m2repository"
else
  log "未检测到离线仓库(可选)"
fi

# Gradle Offline 模式建议
log "可使用: $ROOT_DIR/scripts/codex-build-offline.sh assembleDebug"

popd >/dev/null
