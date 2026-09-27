#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
weather_source="${1:-$repo_root/SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Weather/WeatherManager.swift}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-weather-lifecycle.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -j 1 -swift-version 6 -typecheck -target arm64-apple-ios17.0 \
  -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
  "$repo_root/Tests/WeatherLifecycleHarness/WeatherDependencies.swift" \
  "$weather_source" \
  "$repo_root/Tests/WeatherLifecycleHarness/Main.swift"
echo 'PASS iOS WeatherManager typecheck against native iPhoneOS SDK'
swiftc -j 1 -swift-version 6 -emit-module -emit-library -module-name CoreLocation \
  -emit-module-path "$test_dir/CoreLocation.swiftmodule" -o "$test_dir/libCoreLocationTest.dylib" \
  "$repo_root/Tests/WeatherLifecycleHarness/CoreLocationTestDouble.swift"
swiftc -j 1 -swift-version 6 -I "$test_dir" -L "$test_dir" -lCoreLocationTest \
  -Xlinker -rpath -Xlinker "$test_dir" -o "$test_dir/weather-lifecycle" \
  "$repo_root/Tests/WeatherLifecycleHarness/WeatherDependencies.swift" \
  "$weather_source" \
  "$repo_root/Tests/WeatherLifecycleHarness/Main.swift"
"$test_dir/weather-lifecycle"
