# SkyBridge Compass Pro (macOS)

SkyBridge Compass Pro 是面向 macOS 的设备管理与远程控制应用。本仓库已精简为仅包含 macOS 相关源码与论文资料。

## 目录结构

- `Sources/`：macOS 应用与核心模块源码
- `Sources/Vendor/`：随项目分发的第三方框架
- `Tests/`：测试用例
- `Docs/`：论文与图表素材

## 环境要求

- macOS 14+
- Xcode 15+
- Swift 6.2+（由 Xcode 版本提供）

## 构建与运行

1. 用 Xcode 打开 `Package.swift`
2. 选择 `SkyBridgeCompassApp` 作为运行目标
3. 直接运行

命令行测试：

```bash
swift test
```

## 说明

仓库不包含构建产物与敏感配置（密钥、证书、运行时凭据等），相关内容已加入忽略规则。
