#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[WIRE-CANON] running wire canonicalization regression tests"
swift test --filter SkyBridgeCoreTests.WireCanonicalizationTests
swift test --filter SkyBridgeCoreTests.InboundHandshakeAdapterTests
echo "[WIRE-CANON] passed"
