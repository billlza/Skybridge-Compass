#!/usr/bin/env bash
set -euo pipefail

# 将本机 Gradle 缓存中的工件（.jar/.pom）导入为 Maven 本地离线仓
# 目标目录：third_party/m2repository
# 使用方式：
#   ./scripts/codex-offline-import.sh [缓存来源目录，默认~/.gradle/caches/modules-2/files-2.1]

SRC_DEFAULT="$HOME/.gradle/caches/modules-2/files-2.1"
DST="third_party/m2repository"
SRC_DIR=${1:-$SRC_DEFAULT}

echo "[offline-import] 源目录: $SRC_DIR"
echo "[offline-import] 目标目录: $DST"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "[offline-import] 未找到 Gradle 缓存目录: $SRC_DIR" >&2
  echo "[offline-import] 请先在联网环境下构建一次项目以生成依赖缓存。" >&2
  exit 1
fi

mkdir -p "$DST"

# 仅复制需要的工件与元数据，保留 group/name/version 目录结构
rsync -a \
  --prune-empty-dirs \
  --include='*/' \
  --include='*.jar' \
  --include='*.pom' \
  --exclude='*' \
  "$SRC_DIR/" "$DST/"

echo "[offline-import] 导入完成"

