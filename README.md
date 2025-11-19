# SkyBridge Compass Pro（iOS 客户端）

本仓库聚焦 iPhone 端的 SkyBridge Compass Pro 客户端，实现与 mac 版本一致的星空视觉、量子安全协议和跨设备控制体验。若需完整的交互与技术路线，请查阅 [IOS_CLIENT_DESIGN.md](IOS_CLIENT_DESIGN.md)。

## 仓库结构

```
SkyBridge Compass Pro/
├── IOS_CLIENT_DESIGN.md            # iOS 客户端完整设计稿
├── README.md
├── ios-app/                        # SwiftUI iOS App 包结构
│   ├── Package.swift               # SwiftPM + .iOSApplication
│   ├── Info.plist                  # 权限与场景描述
│   └── Sources/
│       ├── SkybridgeCompassApp/    # App 入口、RootView、Tabs、资源
│       ├── SkyBridgeDesignSystem/  # Liquid Glass、GlassCard、背景
│       ├── SkyBridgeCore/          # App 状态、天气/网络/会话模型
│       ├── DeviceDiscoveryKit/     # 设备模型
│       ├── RemoteDesktopKit/       # 会话 / 传输任务模型
│       ├── QuantumSecurityKit/     # PQC 状态模型
│       ├── SettingsKit/            # 性能 & 网络配置
│       └── SkyBridgeWidgets/       # Widget 数据占位
└── web-dashboard/                  # Web 仪表板（共享的远程监控界面）
    ├── src/
    │   ├── components/            # React 组件
    │   ├── services/              # 服务层
    │   ├── hooks/                 # React Hooks
    │   └── ...
    ├── package.json
    └── ...
```

## iOS 客户端蓝图

### 设计与交互
- 🌌 **星空背景 + Liquid Glass**：SwiftUI 4 + Swift 6.2.1，17–18 上使用 `.ultraThinMaterial`，iOS 26 自动切换官方 Liquid Glass。
- 🧭 **底部导向导航**：浮动 TabBar、顶部状态行与底部玻璃操作台，保证单手操作和安全区适配。
- 🪟 **模块化玻璃组件**：`SkyBridgeDesignSystem` 中提供 `GlassCard`、`GlassPanel`、`GlassBottomSheet` 等复用组件。

### 技术模块
- 🧩 **共享 Swift Packages**：`SkyBridgeCore`（会话/传输）、`DeviceDiscoveryKit`（发现）、`RemoteDesktopKit`（视频流）、`QuantumSecurityKit`（PQC）、`SettingsKit`（配置）、`SkyBridgeWidgets`（Widget/Live Activity）。
- ⚙️ **并发与网络**：async/await、AsyncSequence、Bonjour + 自研发现算法、P2P/中继自动切换。
- 🔒 **量子安全**：iOS 26 优先 CryptoKit PQC + Secure Enclave；iOS 17–18 使用 `QuantumSecurityKit` 并清晰标注“软件实现/实验性”。

### 迭代阶段
1. **阶段 0**：项目初始化、Target/Package 划分、Design System 搭建。
2. **阶段 1**：导航骨架、星空背景、底部 Liquid Glass 骨架。
3. **阶段 2**：主控台与天气卡片（wttr.in + AQI 数据源）。
4. **阶段 3**：设备发现列表、底部连接 Sheet。
5. **阶段 4**：文件传输与远程桌面入口卡片。
6. **阶段 5**：高级设置面板（性能、网络实验、量子安全、重置）。

### Widget / Live Activity
- 🏠 **主屏/锁屏 Widget**：快速连接、系统状态、性能模式切换。
- 🎛️ **交互式 Widget（iOS 17/18）**：AppIntent + Toggle/Buttons 控制 PQC、性能模式。
- 🕳️ **Dynamic Island & Live Activities**：远程会话、文件传输、量子安全状态三大场景，提供紧凑/展开布局与操作按钮。

### 兼容策略
- `@available(iOS 26, *)` 包裹 Liquid Glass 与系统 PQC 代码，低版本 fallback。
- 17/18 降级模糊层级，保障性能；26 充分使用 GPU 优化过的材质。
- Widget 能力按系统分层：17（互动主屏）、18（控制组件）、26（色彩/tint 自定义）。

## Web 仪表板
- 🎛️ **设备管理**: 统一监控与控制入口
- 🔍 **设备发现**: 浏览器侧的 WebRTC/Bonjour 混合策略
- 📊 **实时监控**: 设备状态、会话指标、量子安全状态
- 🎨 **现代 UI**: React + Next.js + Tailwind CSS

## 技术架构

### 设备发现机制
- **Bonjour/mDNS**: 本地网络设备广播和发现
- **WebRTC**: 浏览器端 ICE 候选分析
- **WebSocket**: 实时通信和状态同步
- **STUN 服务器**: NAT 穿透和网络拓扑分析

### 安全机制
- **TLS 1.3**: 端到端加密通信
- **证书固定**: 防止中间人攻击
- **设备认证**: 基于证书的设备身份验证
- **连接安全**: 安全的 P2P 连接建立

## 快速开始

### iOS 客户端
```bash
cd ios-app
open Package.swift   # 或者 xed .，由 Xcode 26 生成项目
```

选择 `SkybridgeCompassApp` 运行即可查看 Stage 1 的 RootView + 浮动 TabBar + 底部 Liquid Glass 体验。

### Web 仪表板
```bash
cd web-dashboard
npm install
npm run dev
```

访问 http://localhost:3000 查看 Web 仪表板

## 开发环境

- **iOS**: Xcode 26（目标），Swift 6.2.1，SwiftUI 4，ActivityKit/WidgetKit。
- **Web**: Node.js 18+, React 18+, Next.js 14+, Tailwind CSS。
- **工具**: Git、npm/yarn、AppIntents/ActivityKit CLI。

## 贡献指南

1. Fork 项目
2. 创建功能分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 打开 Pull Request

## 许可证

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情

## 联系方式

如有问题或建议，请通过以下方式联系：

- 创建 Issue
- 发送邮件
- 提交 Pull Request

---

**SkyBridge Compass Pro** - 连接你的数字世界 🌉
