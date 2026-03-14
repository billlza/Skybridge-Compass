# SkyBridge Compass iOS - Current Validation Snapshot

这份文档取代早期“项目创建完成报告”。旧报告中的符号链接、`Package.swift` 直开、测试待实现等描述已经不再准确。

## 当前状态

- iOS 工程入口：`SkyBridgeCompass-iOS.xcodeproj`
- 主 scheme：`SkyBridgeCompass-iOS`
- 测试 target：`SkyBridgeCompassiOSTests`
- UI 测试 target：`SkyBridgeCompassiOSUITests`
- 共享协议/握手契约：已与 macOS 核心对齐
- 文档状态：`README.md`、`BUILD.md`、`QUICKSTART.md` 为当前权威说明

## 2026-03-14 已验证项

- `xcodebuild -project "SkyBridgeCompass-iOS.xcodeproj" -scheme "SkyBridgeCompass-iOS" ... build` 通过
- `xcodebuild test -project "SkyBridgeCompass-iOS.xcodeproj" -scheme "SkyBridgeCompass-iOS" ...` 通过
- `SkyBridgeCompassiOSTests` 共 35 个测试通过
- `SkyBridgeCompassiOSUITests` 最小 smoke 通过（启动 + 游客入站 + 主 tab 导航）
- 主 scheme 的 shared test plan 已修正，可直接在 Xcode 中 `⌘U`
- Apple PQC 路径在 iOS 26 SDK 模拟器构建下可用
- handshake identity pinning 契约已与共享核心收口

## 当前已收口的历史偏差

- 不再要求运行 `setup_symlinks.sh`
- 不再把“打开 `Package.swift`”当作主入口
- 不再把 `swift build --package-path ...` 当作完整 iOS app 验证
- 不再把 `HAS_APPLE_PQC_SDK` 视为必须手工逐次添加的开关

## 仍需了解的边界

- 本地网络发现与部分系统权限行为在模拟器上天然受限，真机联调仍然重要
- 当前 XCUITest 只覆盖最小 smoke，尚未覆盖配对、传输、远程控制等深层流程
- PQC-only 握手仍依赖对端 KEM 公钥信任材料；首次配对未完成时，可能仍看到 bootstrap/fallback 提示

## 建议使用方式

```bash
cd "/path/to/SkyBridge Compass iOS"
open SkyBridgeCompass-iOS.xcodeproj
```

```bash
xcodebuild test \
  -project "SkyBridgeCompass-iOS.xcodeproj" \
  -scheme "SkyBridgeCompass-iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'
```
