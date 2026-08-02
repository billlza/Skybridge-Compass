# SkyBridge Compass iOS - Current File Map

这份文件不再尝试维护“创建时一次性生成了哪些文件”的历史清单，而是保留当前仍然有用的目录映射。

## Top Level

- `SkyBridgeCompass-iOS.xcodeproj`：主工程入口
- `Package.swift`：SwiftPM 清单，主要用于依赖解析与部分模块化构建
- `README.md`：当前功能与协议说明
- `BUILD.md`：签名、构建、测试与发布
- `QUICKSTART.md`：日常启动路径

## App Sources

- `SkyBridgeCompassiOS/Sources/App`：App 生命周期与启动流程
- `SkyBridgeCompassiOS/Sources/Core`：协议、握手、provider、策略、平台抽象
- `SkyBridgeCompassiOS/Sources/Managers`：业务管理器
- `SkyBridgeCompassiOS/Sources/ViewModels`：状态与展示逻辑
- `SkyBridgeCompassiOS/Sources/Views`：SwiftUI 页面与组件
- `SkyBridgeCompassiOS/Resources`：Assets 与资源
- `SkyBridgeCompassiOS/Supporting Files`：`Info.plist` 等工程支持文件

## Extensions And Tests

- `Widgets`：Widget extension
- `SkyBridgeCompassiOSTests`：当前 XCTest 套件

## Vendor And Local Packages

- `LocalPackages/WebRTCLocal` (removed after convergence on exact-pinned remote WebRTC)
- `LocalPackages/OQSRAIILocal` (removed; iOS consumes the root `OQSRAII` product)
- `Vendor/WebRTC` (removed; exact-pinned SwiftPM artifact is the sole WebRTC source)
- `Vendor/liboqs.xcframework` (removed; `../Sources/Vendor/liboqs.xcframework` is the sole liboqs artifact)

## Notes

- 旧文档里关于 `Shared/`、符号链接 `SkyBridgeCore/`、`setup_symlinks.sh` 的描述已失效
- 当前应优先从 `xcodeproj` 与 `SkyBridgeCompassiOS/Sources` 理解项目结构
