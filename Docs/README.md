# SkyBridge 云桥司南 - 技术文档索引

> 最后更新: 2025-12-13

## 📚 文档列表

### 快速入门
- [**快速接入指南**](SkyBridge_QuickStart.md) - 5 分钟快速接入云桥司南

### 跨平台 API
- [**跨平台 API 文档**](SkyBridge_CrossPlatform_API.md) - 完整的协议规范和平台实现指南
  - WebSocket 信令协议
  - 能力协商机制
  - 远程输入事件格式
  - 文件传输协议
  - 加密与安全
  - Windows/Android/Linux/iOS 实现示例

### 设备发现
- [**跨平台设备发现指南**](SkyBridge_Device_Discovery.md) - 确保不同平台设备互相发现
  - mDNS/Bonjour 服务注册
  - TXT 记录规范
  - 各平台实现代码
  - 互操作性检查清单
  - 常见问题排查

### 架构设计
- [**跨平台设备发现与连接技术说明**](跨平台设备发现与连接技术说明.md) - macOS 版详细技术规范
  - 四种连接方式
  - 文件传输实现
  - 远程桌面实现
  - 安全与隐私

### 其他
- [**登录方式技术说明**](登录方式技术说明.md) - 认证与登录机制

---

## 🎯 按平台查找

| 平台 | 推荐阅读 |
|------|----------|
| **Windows** | [快速入门](SkyBridge_QuickStart.md) → [API 文档 §8.1](SkyBridge_CrossPlatform_API.md) → [设备发现 §3.3](SkyBridge_Device_Discovery.md) |
| **Android** | [快速入门](SkyBridge_QuickStart.md) → [API 文档 §8.2](SkyBridge_CrossPlatform_API.md) → [设备发现 §3.2](SkyBridge_Device_Discovery.md) |
| **Linux** | [快速入门](SkyBridge_QuickStart.md) → [API 文档 §8.3](SkyBridge_CrossPlatform_API.md) → [设备发现 §3.4](SkyBridge_Device_Discovery.md) |
| **iOS** | [快速入门](SkyBridge_QuickStart.md) → [API 文档 §8.4](SkyBridge_CrossPlatform_API.md) → [设备发现 §3.1](SkyBridge_Device_Discovery.md) |

---

## 🔑 核心概念速查

| 概念 | 说明 | 文档位置 |
|------|------|----------|
| 服务类型 | `_skybridge._tcp` | [设备发现 §2.1](SkyBridge_Device_Discovery.md) |
| WebSocket 端点 | `ws://127.0.0.1:7002/agent` | [API 文档 §3.1](SkyBridge_CrossPlatform_API.md) |
| 协议版本 | `1.0.0` | [API 文档 §1.2](SkyBridge_CrossPlatform_API.md) |
| 坐标系统 | 归一化 (0.0-1.0) | [API 文档 §5.1](SkyBridge_CrossPlatform_API.md) |
| 加密模式 | classic / pqc / hybrid | [API 文档 §7.1](SkyBridge_CrossPlatform_API.md) |

---

**文档维护**: SkyBridge Compass Team
