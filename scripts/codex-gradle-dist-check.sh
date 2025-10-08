#!/usr/bin/env bash
set -euo pipefail

ZIP="/Users/macbookpro/Desktop/yunqiao-sinan-workspace/third_party/gradle/gradle-9.0.0-bin.zip"

if [[ -f "$ZIP" ]]; then
  echo "[gradle-dist] OK: $ZIP 存在"
else
  echo "[gradle-dist] 缺少分发包: $ZIP"
  echo "[gradle-dist] 请在可联网机器执行:"
  echo "  curl -fL -o gradle-9.0.0-bin.zip https://services.gradle.org/distributions/gradle-9.0-bin.zip"
  echo "  然后放置到: $ZIP"
  exit 1
fi

