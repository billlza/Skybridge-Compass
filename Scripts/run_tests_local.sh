#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="$ROOT_DIR/.swiftpm-cache"
MODULE_CACHE_DIR="$ROOT_DIR/.swiftpm-module-cache"

mkdir -p "$CACHE_DIR"
mkdir -p "$MODULE_CACHE_DIR"

SWIFTPM_CACHE_PATH="$CACHE_DIR" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
swift test
