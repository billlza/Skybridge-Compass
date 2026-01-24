# 🚀 SkyBridge Compass iOS - 快速入门（已更新）

## ⚡ 只需 2 步即可运行！

### 步骤 1: 用 Xcode 打开项目（30秒）

```bash
cd "/Users/bill/Desktop/SkyBridge Compass iOS"
open Package.swift
```

### 步骤 2: 运行！（30秒）

在 Xcode 中：
1. 等待 Swift Package 解析完成（约 10-20 秒）
2. 选择目标设备：**iPhone 15 Pro** 模拟器
3. 按 `⌘R` 运行

**就这样！应用会立即启动。** 🎉

---

## ✅ 已修复的问题

之前的 "invalid custom path" 错误已完全解决。

### 改动说明

- ✅ 简化了 Package.swift 配置
- ✅ 移除了符号链接依赖
- ✅ 所有代码现在都在主应用目录下
- ✅ 不再需要运行 setup_symlinks.sh

### 新的项目结构（更简单！）

```
SkyBridge Compass iOS/
├── Package.swift                 # ✅ 已修复
├── SkyBridgeCompassiOS/
│   └── Sources/
│       ├── App/                 # 应用入口
│       ├── Views/               # 所有视图
│       ├── Managers/            # 所有管理器
│       ├── Utilities/           # 工具类
│       └── Models.swift         # 数据模型
├── Widgets/                     # Widget
└── Tests/                       # 测试
```

---

## 🎯 第一次使用

### 1. 启动应用

应用启动后，你会看到登录界面。

### 1.5 如果弹出 “Supabase 配置缺失”

这表示当前运行方式没有读到 Supabase 配置。处理方式：

- 在登录页点击 **“Supabase 配置”**，填入 `SUPABASE_URL` / `SUPABASE_ANON_KEY`，保存即可（写入 Keychain，优先级最高）。

读取优先级（从高到低）：
- **Keychain**（设置保存）
- **`Info.plist`**（Xcode 工程 App target）
- **`SupabaseConfig.plist`**（仅 SwiftPM：打开 `Package.swift` 运行时）

### 2. 快速体验

点击 **"以游客身份继续"** 按钮

### 3. 探索功能

应用有 4 个主要标签：

#### 📡 发现
- 点击右上角的扫描按钮
- 查看发现的设备列表
- 点击设备查看详情

#### 📺 远程
- 连接设备后可以查看远程屏幕
- 支持触摸控制

#### 📁 文件
- 发送和接收文件
- 查看传输历史

#### ⚙️ 设置
- 配置主题、语言
- 查看 PQC 加密设置
- 管理账户

---

## 📱 在真机上运行（可选）

### 前提条件
- iOS 17+ 设备
- Apple 开发者账号
- Lightning/USB-C 数据线

### 步骤

1. **连接设备到 Mac**

2. **配置签名**
   - 在 Xcode 左侧，点击项目文件
   - 选择 "SkyBridgeCompassiOS" target
   - 在 "Signing & Capabilities" 标签：
     - Team: 选择你的开发团队
     - Bundle Identifier: 改为 `com.yourname.skybridge.ios`

3. **信任证书**
   - 在 iOS 设备上：设置 → 通用 → VPN与设备管理
   - 点击你的开发者证书 → 信任

4. **运行**
   - 在 Xcode 顶部选择你的设备
   - 按 `⌘R`

---

## 🌐 与 macOS 互通（高级）

### 准备

1. **在 Mac 上启动 macOS 版本**
   ```bash
   cd "/Users/bill/Desktop/SkyBridge Compass Pro release"
   # 用 Xcode 打开并运行
   ```

2. **确保两个设备在同一 Wi-Fi**

### 测试步骤

1. **iOS 上打开"发现"标签**
2. **点击扫描按钮**（右上角）
3. **应该看到 Mac 出现在列表中**
4. **点击 Mac 设备**
5. **点击"连接设备"**
6. **完成 PQC 验证**（输入 6 位验证码）

### 验证互通

- ✅ 能看到 Mac 设备
- ✅ 能建立加密连接
- ✅ 能查看 Mac 屏幕
- ✅ 能传输文件

---

## 🐛 故障排除

### Q: Xcode 显示编译错误
**A:** 
1. 清理构建：Product → Clean Build Folder (⌘⇧K)
2. 重新构建：Product → Build (⌘B)

### Q: 模拟器启动失败
**A:**
1. 重启 Xcode
2. 重新选择模拟器
3. 或选择不同的 iOS 版本模拟器

### Q: 找不到设备（网络发现）
**A:**
- 本地网络发现在模拟器上受限
- 建议使用真机测试
- 或者等待 iCloud 发现功能（需要配置）

### Q: Widget 在哪里？
**A:**
- 长按主屏幕
- 点击左上角 "+"
- 搜索 "SkyBridge"
- 添加 Widget（有 3 种尺寸）

---

## 💡 开发技巧

### 使用 Xcode 预览

在任何视图文件底部，你会看到 `#Preview` 代码：

```swift
#Preview {
    DeviceDiscoveryView()
        .environmentObject(DeviceDiscoveryManager.shared)
}
```

点击 Xcode 右侧的 "Resume" 按钮查看实时预览！

### 快捷键

- `⌘R` - 运行
- `⌘.` - 停止
- `⌘B` - 构建
- `⌘⇧K` - 清理
- `⌘U` - 运行测试

### 查看日志

运行应用后，在 Xcode 底部的控制台会看到日志：

```
🚀 SkyBridge Compass iOS 已启动
📱 iOS 版本: 17.2
📲 设备类型: iPhone
✅ PQC 加密系统初始化完成
✅ 设备发现服务已启动
```

---

## 🎊 完成！

现在你已经成功运行了 SkyBridge Compass iOS！

### 接下来

- 📚 查看 `FIXED.md` 了解修复详情
- 📖 查看 `PROJECT_SUMMARY.md` 了解架构
- 🔧 查看 `BUILD.md` 了解详细配置

### 享受使用！

这是一个功能完整的跨平台设备管理应用，具有：
- 🔒 后量子加密
- 📱 现代 iOS 设计
- 🌐 与 macOS 互通
- ⚡ 高性能实现

---

**需要帮助？** 查看其他文档或提出问题！
