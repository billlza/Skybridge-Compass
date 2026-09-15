# macOS / iOS 多云天气移植验收

苹果两端的多云效果已移植，完整 Release 配置构建及相关测试通过。后续已修正应用帧调度，并抓到 iPhone 告警的精确调用栈：来自苹果 Metal HUD 的截图回调。告警仍会出现，正式发布验收保持开放。最新六项原生测试、构建和根因记录见[绘制生命周期复核](../20260909-drawable-lifecycle/review.md)。Windows 按后续要求暂缓。此次保留各端正式版安装，真机测试使用独立验证宿主。以下表格保留首次移植验证记录。

## 效果与根因

此前 Mac 与 iOS 的生产多云入口主要用二维云团，缺少 Android 验收版本的三维密度、遮光、透射和统一天空合成。现已切换为共用的 `SkyBridgeWeatherRendering` Metal 模块，沿用 Android 的密度数据、48/24 步积分、风移、相机投影和明暗参数。

Mac、iPhone、iPad 各五张真实 GPU 帧与 Android 验收图比较，共 15 组。最大的平均 RGB 通道差为 0.058433/255，最大单通道差为 2/255，全部像素不透明。涵盖三档质量、后续风移和宽屏画面。图像及数值记录为 `macos-gpu/`、`iphone-gpu/`、`ipad-gpu/`、`render-parity.json`。

## 实施与架构审查

- `Packages/SkyBridgeWeatherRendering`：共享云密度、Metal 着色器、原生视图适配和有上限的 GPU 资源所有权。使用显式 sRGB 显示空间；密度图集按原始 RGBA8 数据读取。
- Mac 的 `CinematicCloudyEffectView`：保留原有配置、手势透明度和远程会话策略，接入共享渲染。
- iOS 的 `DashboardWeatherEffectsView`：多云分支接入同一模块，移除该分支的二维云团；由原有天气、无障碍、省电及温控策略驱动。
- `Package.swift`、iOS 工程和 `.gitignore`：注册第一方共享模块，确保资源和源文件纳入构建与版本控制。
- `Scripts/sync_cloud_weather.py`：从已认可的 Android 实现导出并核对 Metal 云场及密度图集。
- `Tests/HostApp`：使用独立身份 `com.skybridge.weather.rendering.validation`，在真实设备运行生产渲染模块及同一套测试。

渲染模块不依赖账户、网络或持久化服务。没有增加第三方运行时依赖。短边最多 600 像素、长边最多 1300 像素，低质量为 75% 尺寸，最多两帧 GPU 工作在途。编译资源时离开主 actor；静态模式按实际参数或尺寸变化重绘；帧资源通过 autorelease pool 及时释放。资源缺失、解码长度错误和 GPU 错误均有显式处理边界。

## 实际验证命令

以下默认工作目录为本仓库根目录。完整输出保存在同目录所列日志中。

| 命令 | 结果 | 日志 |
|---|---|---|
| `python3 Scripts/sync_cloud_weather.py --android-root '/Users/bill/Desktop/SkyBridge Compass - Android' --check` | 着色器与密度数据均精确一致 | 本次命令输出 |
| `python3 -m py_compile Scripts/sync_cloud_weather.py` | 通过 | 本次命令输出 |
| `xcrun -sdk macosx metal -Werror -c Packages/SkyBridgeWeatherRendering/Sources/SkyBridgeWeatherRendering/Resources/CloudVolume.metal -o design/weather/20260909-cloud-parity/cloud-volume-macos.air` | 通过，0 error / warning | `cloud-volume-macos.air` |
| `xcrun -sdk iphoneos metal -Werror -c Packages/SkyBridgeWeatherRendering/Sources/SkyBridgeWeatherRendering/Resources/CloudVolume.metal -o design/weather/20260909-cloud-parity/cloud-volume-ios.air` | 通过，0 error / warning | `cloud-volume-ios.air` |
| `swift test --package-path Packages/SkyBridgeWeatherRendering -Xswiftc -warnings-as-errors` | 5/5 通过，0 error / warning | `macos-tests-delivery.log` |
| `swift test --filter DashboardWeatherEffectsPerformanceContractTests -Xswiftc -warnings-as-errors --disable-automatic-resolution` | 4/4 通过，0 error / warning | `dashboard-contract-tests.log` |
| `SKYBRIDGE_RELEASE_EXCLUDE_SMOKE_SUPPORT=1 swift build -c release --product SkyBridgeCompassApp -Xswiftc -warnings-as-errors --disable-automatic-resolution` | 完整 Mac Release 配置构建通过，0 error / warning | `macos-release-delivery.log` |
| `xcodebuild -project 'SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj' -scheme SkyBridgeCompass-iOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/skybridge-cloud-parity-ios-product -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_SUPPRESS_WARNINGS=NO GCC_TREAT_WARNINGS_AS_ERRORS=YES build` | 完整 iOS Release 配置构建通过，0 error / warning | `ios-release-delivery.log` |

真机命令在 `Packages/SkyBridgeWeatherRendering/Tests/HostApp` 执行：

```sh
xcodebuild -project CloudRenderingHost.xcodeproj -scheme CloudRenderingHost \
  -destination 'platform=iOS,id=00008140-000E788401C0801C,arch=arm64' \
  -destination-timeout 30 -parallel-testing-enabled NO \
  -derivedDataPath /tmp/skybridge-cloud-native-host \
  -resultBundlePath '<本验收目录>/iphone-native-cloud-pool.xcresult' \
  -allowProvisioningUpdates SWIFT_SUPPRESS_WARNINGS=NO test

xcodebuild -project CloudRenderingHost.xcodeproj -scheme CloudRenderingHost \
  -destination 'platform=iOS,id=00008132-0006452C1138801C,arch=arm64' \
  -destination-timeout 30 -parallel-testing-enabled NO \
  -derivedDataPath /tmp/skybridge-cloud-native-host \
  -resultBundlePath '<本验收目录>/ipad-native-cloud-pool.xcresult' \
  SWIFT_SUPPRESS_WARNINGS=NO test-without-building
```

iPhone 16 Pro、iPad Pro M4 均为 5/5 通过，编译诊断为零。测试检查三档云层的遮挡与明暗、下部阅读区域、风移连续性、宽屏投影、渲染尺寸、暂停时间、真实原生视图加载及显示色彩空间。iPhone 的运行时提示单独列于下节，不能被测试通过状态抵消。

iOS Release `.app` 中的 Metal 源和 RGBA8 图集已与当前源资源逐字节核对。此处的 Release 构建是编译与资源集成验证，iOS 使用 `CODE_SIGNING_ALLOWED=NO`，不是可安装的签名 IPA。没有制作或覆盖安装正式 DMG/IPA。

## 未关闭项及证据边界

1. iPhone 开启 Metal HUD 的日志出现：`[CAMetalLayerDrawable texture] should not be called after already presenting this drawable. Get a nextDrawable instead.` 首次五项断言及图像均通过；后续已定位到 `libMTLHud.dylib` 的 `_snapshotDrawable:state:`，应用调度修正后六项测试通过，但系统提示仍存在。精确调用栈见 `../20260909-drawable-lifecycle/stale-drawable-stack.txt`。
2. 在 iPad 对同一二进制仅向测试进程注入 `MTL_HUD_ENABLED=1` 后，五项测试通过，出现 HUD 重复统计项日志，但未复现上述 drawable 提示；默认 iPad 测试没有该提示。记录为 `ipad-hud-enabled.log` 和 `ipad-metal-hud-diagnostic.log`。未修改设备全局 HUD 设置。这一对照不代表 iPhone 提示已解决；后续 iPhone 已完成调用栈采集，来源为系统 HUD，见最新复核记录。
3. 本次未做长时间温升、功耗和持续帧率验收，也未覆盖其他 GPU 或旧系统的实际运行。
4. 正式版安装保留；Windows 移植按后续指令暂缓。

原生帧资源释放方式遵循 [Apple 的 CAMetalLayer 文档](https://developer.apple.com/documentation/QuartzCore/CAMetalLayer)。早期 shader 保留字、测试表达式类型推导、iOS 色彩空间入口、测试宿主屏幕方向与 Xcode 编译参数问题已修正；失败日志保留，没有降低断言、跳过失败测试或屏蔽编译告警。

机器可读结果：`validation-results.json`。本次文件范围：`source-files.txt`。修改前文件保存在 `before/`。
