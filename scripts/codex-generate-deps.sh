#!/usr/bin/env bash
set -euo pipefail

# 生成依赖清单，便于预热/校验离线仓。
# 使用： ./scripts/codex-generate-deps.sh [module=app]

MODULE=${1:-app}

if [[ ! -x ./gradlew ]]; then
  echo "[deps] 未找到 ./gradlew，请在项目根目录执行。" >&2
  exit 1
fi

OUT_DIR="build/codex"
OUT_FILE_TREE="$OUT_DIR/${MODULE}-dependency-tree.txt"
OUT_FILE_COORDS="$OUT_DIR/${MODULE}-coordinates.txt"
mkdir -p "$OUT_DIR"

echo "[deps] 输出依赖树: $OUT_FILE_TREE"
./gradlew -q "${MODULE}:dependencies" > "$OUT_FILE_TREE" || true

echo "[deps] 解析依赖坐标: $OUT_FILE_COORDS"
# 从依赖树中抽取 group:name:version 形式的坐标（粗略提取）
grep -Eo "[a-zA-Z0-9_.-]+:[a-zA-Z0-9_.-]+:[0-9][a-zA-Z0-9+_.-]*" "$OUT_FILE_TREE" | \
  sort -u > "$OUT_FILE_COORDS" || true

echo "[deps] 完成，请检查 $OUT_FILE_COORDS 并按需预热离线仓。"

