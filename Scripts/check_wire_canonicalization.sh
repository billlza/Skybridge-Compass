#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[WIRE-CANON] running wire canonicalization regression tests"
bash Scripts/run_swift_test_filter.sh SkyBridgeCoreTests.WireCanonicalizationTests
bash Scripts/run_swift_test_filter.sh SkyBridgeCoreTests.MLDSA87WireContractTests
bash Scripts/run_swift_test_filter.sh SkyBridgeCoreTests.InboundHandshakeAdapterTests
echo "[WIRE-CANON] passed"
