# SkyBridge Compass iOS - Project Summary

## What This Project Is

`SkyBridge Compass iOS` 是当前仓库内维护的 iOS app 工程，使用独立的 `xcodeproj` 作为主要入口，并在协议层与 macOS 共享同一套握手/信任/策略语义。

## Authoritative Entry Points

- App 工程：`SkyBridgeCompass-iOS.xcodeproj`
- 主 scheme：`SkyBridgeCompass-iOS`
- XCTest target：`SkyBridgeCompassiOSTests`
- XCUITest target：`SkyBridgeCompassiOSUITests`
- 主文档：`README.md`
- 构建/签名/测试：`BUILD.md`
- 快速启动：`QUICKSTART.md`

## Current Architecture

- App 层：`SkyBridgeCompassiOS/Sources/App`
- 视图层：`SkyBridgeCompassiOS/Sources/Views`
- 核心协议/握手/策略：`SkyBridgeCompassiOS/Sources/Core`
- Widget：`Widgets`
- 测试：`SkyBridgeCompassiOSTests`

## Protocol Alignment Notes

- iOS 端已不再依赖符号链接去引用 macOS 工程目录
- handshake identity pinning 使用规范化协议身份指纹
- `MessageA` / `MessageB` 的验签后 pinning 现在基于解码后的 `IdentityPublicKeys`
- iOS 26 SDK 构建下，Xcode 工程已自动启用 `HAS_APPLE_PQC_SDK`

## Validation Snapshot

截至 2026-03-14，以下检查已通过：

- iOS 主 scheme simulator build
- iOS 主 scheme simulator test
- `SkyBridgeCompassiOSTests` 35 项 XCTest
- `SkyBridgeCompassiOSUITests` 启动与主导航 smoke
- macOS 共享核心 `swift test`

## Known Non-Issues That Used To Look Like Issues

- `swift build --package-path "SkyBridge Compass iOS"` 不能代表完整 app 工程状态
- 早期 shared scheme 指向错误 test plan 的问题已修复
- 旧文档中关于 `setup_symlinks.sh`、`open Package.swift` 的流程已过时

## Remaining Practical Gaps

- 当前 XCUITest 仍是最小 smoke 骨架，尚未覆盖更深的交互链路
- 真机权限、局域网发现、Widget 行为仍建议做设备侧 smoke
- PQC-only 首次建联仍取决于对端 KEM 公钥是否已进入信任存储
