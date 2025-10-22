# SkyBridge Compass Pro

SkyBridge Compass Pro 是一个跨平台设备管理和远程控制解决方案，支持 macOS、iOS、Android、Windows 和 Linux 设备之间的无缝连接和协作。

## 项目结构

```
SkyBridge Compass Pro/
├── SkyBridge Compass Pro/          # macOS 主应用
│   ├── SkyBridge_Compass_Pro.swift # 应用入口
│   ├── ContentView.swift           # 主界面
│   ├── P2PDiscoveryService.swift   # P2P 设备发现服务
│   ├── P2PModels.swift            # 数据模型
│   └── ...
├── web-dashboard/                  # Web 仪表板
│   ├── src/
│   │   ├── components/            # React 组件
│   │   ├── services/              # 服务层
│   │   ├── hooks/                 # React Hooks
│   │   └── ...
│   ├── package.json
│   └── ...
└── README.md
```

## 功能特性

### macOS 应用
- 🔍 **设备发现**: 基于 Bonjour/mDNS 的本地网络设备自动发现
- 🔐 **安全连接**: TLS 1.3 加密，证书固定，设备认证
- 🌐 **NAT 穿透**: STUN 服务器支持，智能 NAT 类型检测
- 📱 **多平台支持**: 支持 macOS、iOS、iPadOS、Android、Windows、Linux

### Web 仪表板
- 🎛️ **设备管理**: 统一的设备监控和管理界面
- 🔍 **设备发现**: 集成的设备发现功能，支持多种发现方式
- 📊 **实时监控**: 设备状态、系统资源、连接统计
- 🎨 **现代 UI**: 基于 React + Next.js + Tailwind CSS

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

### macOS 应用
1. 使用 Xcode 打开项目
2. 选择目标设备或模拟器
3. 点击运行按钮

### Web 仪表板
```bash
cd web-dashboard
npm install
npm run dev
```

访问 http://localhost:3000 查看 Web 仪表板

## 开发环境

- **macOS**: Xcode 15+, Swift 5.9+
- **Web**: Node.js 18+, React 18+, Next.js 14+
- **工具**: Git, npm/yarn

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
