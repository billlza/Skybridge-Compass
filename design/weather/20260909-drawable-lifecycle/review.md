# Apple 多云绘制生命周期复核

应用侧的帧调度修正已通过 Mac、iPhone、iPad 的原生测试及两端完整 Release 配置构建。整体状态为部分完成：iPhone 的系统 Metal HUD 告警已找到精确来源，但尚未消除，不能宣称运行时诊断全部清零。iPhone 调试器已解除连接，正式应用和数据保留。

## 根因与证据

iPhone 16 Pro / iOS 26.5（23F77）上的告警来自苹果 `libMTLHud.dylib`，调用链为：

```
CAMetalDrawable.texture
HUDMTLLayerTracking._snapshotDrawable:state:
HUDMTLLayerTracking._presentOrSignalDrawable: 的回调
CAMetalDrawable.didPresentAtTime:
CAMetalDrawable.release
Core Animation 合成完成回调
```

[完整现场调用栈](stale-drawable-stack.txt)对应 drawable backing 已经为空时的告警分支。该栈没有应用渲染回调。通过 LLDB 反汇编当前系统的 `-[CAMetalDrawable texture]` 后，在其入口检查接收对象偏移 8 的 backing 指针，仅在为空时抓取栈；[采集脚本](drawable_trace.py)中的偏移只适用于这次已检查的系统二进制，不属于产品代码。

最终应用代码仍可复现一次相同提示，见 `iphone-tests-final.log`。这证明单纯调整应用 drawable 获取方式无法消除该系统 HUD 路径。没有在产品中禁用 HUD、关闭日志、关闭 Metal API 校验或调用私有接口，也没有更改设备全局设置。

另外，原应用在 SwiftUI 更新和原生布局回调中同步调用 `view.draw()`，存在从视图更新重入绘制的路径。这与上面的系统 HUD 告警分开处理。原实现运行同一回归测试时，实际记录到一次同步 draw；最终实现记录为零。[回归基线命令及结果](regression-baseline.json)、`regression-baseline-final.log` 保留旧实现的预期失败，未通过削弱断言处理。

## 实施与架构复核

- `Packages/SkyBridgeWeatherRendering/Sources/SkyBridgeWeatherRendering/CinematicCloudView.swift`：绘制统一由 MetalKit 帧时钟进入。静态参数改变时请求一帧，提交后暂停；GPU 暂时繁忙时保留待绘制状态。窗口脱离时暂停并停止累计动画时间，重新挂载时补画一帧，即使尺寸未改变也生效。
- 继续使用 MetalKit 的 `currentRenderPassDescriptor` / `currentDrawable`，所有 drawable 访问局限于当前绘制回调。排查时尝试的直接 `CAMetalLayer.nextDrawable()` 生产分支已撤回，因为它没有解决系统提示，也没有必要成为第二套管理方式。
- `CloudSurfaceTests.swift`：增加更新回调不得同步 draw 的回归断言；原生窗口测试保留尺寸、色彩空间、像素格式检查，并增加静态更新和离开/重新进入窗口后的调度断言。表面测试串行执行，避免多个测试窗口相互干扰。
- `Tests/HostApp/project.yml` 及生成的共享 scheme：测试明确开启 `MTL_DEBUG_LAYER=1`。这是增强 [Metal API 校验](https://developer.apple.com/documentation/xcode/validating-your-apps-metal-api-usage)，不改变正式应用设置。

改动仍位于共享渲染包和它的测试宿主内，未增加运行时依赖、公共 API、持久化格式或跨层调用。窗口回调弱引用视图与协调器；原有两帧并发上限与完成回调释放逻辑保留。没有新增重试队列、缓存或密码学机制。共享 shader、密度资源以及 Mac/iOS 的业务天气策略保持原先已验证的内容。

## 实际验证

以下命令默认工作目录为 `/Users/bill/Desktop/SkyBridge Compass Pro release`。宿主命令工作目录为 `Packages/SkyBridgeWeatherRendering/Tests/HostApp`。完整机器结果见 [validation-results.json](validation-results.json)。

| 实际命令 | 结果与日志 |
|---|---|
| `swift test --package-path Packages/SkyBridgeWeatherRendering -Xswiftc -warnings-as-errors` | 6/6 通过，0 error / warning；`macos-tests-final.log` |
| `MTL_DEBUG_LAYER=1 swift test --package-path Packages/SkyBridgeWeatherRendering -Xswiftc -warnings-as-errors` | 明确输出 Metal API Validation Enabled，6/6 通过，0 error / warning；`macos-api-validation.log` |
| `xcodegen generate --spec project.yml` | 成功，无诊断；`host-project-generation.log` |
| `xcodebuild -project CloudRenderingHost.xcodeproj -scheme CloudRenderingHost -destination 'platform=iOS,id=00008140-000E788401C0801C,arch=arm64' -destination-timeout 10 -parallel-testing-enabled NO -derivedDataPath /tmp/skybridge-cloud-native-host -resultBundlePath '/Users/bill/Desktop/SkyBridge Compass Pro release/design/weather/20260909-drawable-lifecycle/iphone-final.xcresult' SWIFT_SUPPRESS_WARNINGS=NO test-without-building` | iPhone 最终代码 6/6 通过；编译诊断 0，仍有 1 条系统 HUD drawable 提示和 HUD 重复指标日志；`iphone-tests-final.log` |
| `DEVELOPER_DIR=/Applications/Xcode-27.0.app/Contents/Developer xcodebuild -project CloudRenderingHost.xcodeproj -scheme CloudRenderingHost -destination 'platform=iOS,id=00008132-0006452C1138801C,arch=arm64' -destination-timeout 10 -parallel-testing-enabled NO -derivedDataPath /tmp/skybridge-cloud-native-host -resultBundlePath '/Users/bill/Desktop/SkyBridge Compass Pro release/design/weather/20260909-drawable-lifecycle/ipad-api-validation-final.xcresult' SWIFT_SUPPRESS_WARNINGS=NO test-without-building` | iPadOS 27.0（24A5430a），Metal API Validation Enabled，6/6 通过，0 error / warning；`ipad-api-validation-final.log` |
| `python3 Scripts/sync_cloud_weather.py --android-root '/Users/bill/Desktop/SkyBridge Compass - Android' --check` | Metal shader 与原始密度数据均 exact match |
| `SKYBRIDGE_RELEASE_EXCLUDE_SMOKE_SUPPORT=1 swift build -c release --product SkyBridgeCompassApp -Xswiftc -warnings-as-errors --disable-automatic-resolution` | 完整 Mac Release 配置构建通过，370.11 秒，0 error / warning；`macos-release-final.log` |
| `xcodebuild -project 'SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj' -scheme SkyBridgeCompass-iOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/skybridge-cloud-parity-ios-product -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_SUPPRESS_WARNINGS=NO GCC_TREAT_WARNINGS_AS_ERRORS=YES build` | 完整 iOS Release 配置构建通过，0 error / warning；`ios-release-final.log` |

旧实现的同步绘制回归测试预期失败；最终代码的同一断言通过。原有所有图像、风移、横屏投影、帧时间和窗口断言继续通过，没有跳过测试。

最终三端各五张真实 GPU 图像均与安卓基准比较，共 15 张；最大平均 RGB 通道差值为 0.058432521/255，最大单通道差值为 2/255，全部像素保持不透明。见 [图像对照结果](render-parity-final.json)及 `macos-gpu-final`、`iphone-gpu-final`、`ipad-gpu-final`。这些结果不等于长期功耗或持续帧率测量。

## 工具提示处理与剩余范围

早期 Xcode 26.6 在 iPadOS 27 测试版上提示找不到 DeviceSupport。一次独立 xctestrun 调用还因 iOS 与 DriverKit 目标同时匹配而提示目标歧义。最终改用 Xcode 27 的项目/scheme 目标运行已有二进制，两条提示都消失；原日志保留在 `ipad-tests-final.log`、`ipad-api-validation.log`。没有修改系统默认 Xcode，也没有屏蔽诊断。

Apple HUD 的 drawable 告警是当前真实未关闭项，复现命令为上面的 iPhone 原生测试命令，前提是设备原有 HUD 设置开启。应用不能修改苹果运行库中的截图回调；后续系统修正需要在该设备上重新验证，不能用关闭 HUD 的一次结果代替验收。[Apple HUD 配置文档](https://developer.apple.com/documentation/xcode/customizing-metal-performance-hud)说明 HUD 属于独立的性能诊断覆盖层。

正式 Mac/iOS 应用尚未覆盖安装；本轮设备运行的是 `com.skybridge.weather.rendering.validation` 独立宿主。iOS Release 使用无签名构建参数，不是已签名 IPA。Windows 按用户要求暂缓。
