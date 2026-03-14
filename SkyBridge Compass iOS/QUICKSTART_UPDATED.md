# SkyBridge Compass iOS - Quick Redirect

这份文件保留为兼容旧链接的入口，当前请直接使用以下文档：

- `QUICKSTART.md`：日常启动与联调
- `BUILD.md`：签名、构建、测试与发布
- `README.md`：协议、PQC、互通与运行约束

当前推荐启动方式：

```bash
cd "/path/to/SkyBridge Compass iOS"
open SkyBridgeCompass-iOS.xcodeproj
```

当前推荐自动化验证：

```bash
xcodebuild test \
  -project "SkyBridgeCompass-iOS.xcodeproj" \
  -scheme "SkyBridgeCompass-iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'
```
