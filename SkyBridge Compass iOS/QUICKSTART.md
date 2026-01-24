# 🚀 SkyBridge Compass iOS - 快速入门

欢迎使用 SkyBridge Compass iOS！这是一个完整的、可以与 macOS 版本互通的 iOS 应用。

## ⚡ 5 分钟快速启动

### 步骤 1: 设置符号链接 (30秒)

```bash
cd "/Users/bill/Desktop/SkyBridge Compass iOS"
chmod +x setup_symlinks.sh
./setup_symlinks.sh
```

### 步骤 2: 打开项目 (1分钟)

```bash
open Package.swift
```

Xcode 会自动打开并配置项目。

### 步骤 3: 选择目标设备 (30秒)

在 Xcode 顶部工具栏：
- 点击设备选择器
- 选择 "iPhone 15 Pro" 模拟器（或任何 iOS 17+ 模拟器）

### 步骤 4: 运行！ (30秒)

按 `⌘R` 或点击运行按钮 ▶️

## 🔑 Supabase 配置（如果看到“配置缺失”弹窗）

如果你在登录/注册时看到 **“Supabase 配置缺失（SUPABASE_URL / SUPABASE_ANON_KEY）”**，说明应用没有读到 Supabase 连接信息。

### 最推荐（无需改代码）
- 在登录页点击 **“Supabase 配置”**，填入 `SUPABASE_URL` 和 `SUPABASE_ANON_KEY`，点“保存并生效”（会写入 Keychain）。

### 读取优先级（从高到低）
- **Keychain**（设置里保存的配置）
- **`Info.plist`**（Xcode 工程 App target 的 Info.plist 里写的键）
- **`SupabaseConfig.plist`**（仅在 **打开 `Package.swift`** 作为 SwiftPM 运行时生效，`Bundle.module` 读取）

## 🎯 第一次使用

### 应用启动后

1. **选择认证方式**
   - 点击"以游客身份继续"快速体验
   - 或注册/登录账号

2. **查看设备发现**
   - 切换到"发现"标签
   - 点击右上角扫描按钮
   - 如果 macOS 版本在同一网络，会自动发现

3. **连接 Mac（如果有）**
   - 点击发现的 Mac 设备
   - 查看设备详情
   - 点击"连接设备"
   - 完成 PQC 验证

4. **探索其他功能**
   - 远程桌面：查看并控制连接的设备
   - 文件传输：发送和接收文件
   - 设置：配置应用偏好

## 🔧 真机测试（可选）

### 前提条件
- Apple 开发者账号
- iOS 设备 (iOS 17+)
- Lightning/USB-C 数据线

### 步骤

1. **连接设备**
   ```
   用数据线连接 iPhone/iPad 到 Mac
   ```

2. **配置签名**
   - 在 Xcode 中选择项目
   - 选择 "SkyBridgeCompassiOS" target
   - "Signing & Capabilities" 标签
   - Team: 选择你的开发团队
   - Bundle Identifier: 改为唯一值

3. **信任证书**
   - 在 iOS 设备上：
   - 设置 → 通用 → VPN与设备管理
   - 点击你的开发者证书
   - 点击"信任"

4. **运行**
   - 选择你的设备作为运行目标
   - ⌘R 运行

## 📚 下一步

### 查看文档
- `README.md` - 项目概览
- `BUILD.md` - 详细构建指南  
- `PROJECT_SUMMARY.md` - 项目架构和功能

### 测试 iOS ↔ macOS 互通

1. **在 Mac 上启动 macOS 版本**
   ```bash
   cd "/Users/bill/Desktop/SkyBridge Compass Pro release"
   # 使用 Xcode 打开并运行
   ```

2. **确保两个设备在同一 Wi-Fi**

3. **在 iOS 上发现并连接 Mac**
   - 打开"发现"标签
   - 点击扫描
   - 应该看到 Mac 出现
   - 点击连接

4. **验证 PQC 握手**
   - Mac 和 iOS 都会显示 6 位验证码
   - 确认两边代码一致
   - 输入验证

5. **测试功能**
   - ✅ 查看 Mac 屏幕（远程桌面）
   - ✅ 发送文件到 Mac
   - ✅ 从 Mac 接收文件
   - ✅ 剪贴板同步

## 🐛 常见问题

### Q: 编译错误 "找不到 SkyBridgeCore"
**A:** 运行 `./setup_symlinks.sh` 创建符号链接

### Q: 模拟器找不到设备
**A:** 
- 本地网络发现在模拟器上受限
- 建议使用真机测试
- 或者使用 iCloud 发现（需要配置）

### Q: PQC 握手失败
**A:**
- 确保两个设备都使用最新代码
- 检查网络连接
- 查看日志：Console.app → 搜索 "skybridge"

### Q: Widget 不显示
**A:**
- 长按主屏幕
- 点击左上角 "+"
- 搜索 "SkyBridge"
- 添加 Widget

## 💡 开发技巧

### Xcode 预览

视图文件底部可以使用 SwiftUI 预览：

```swift
#Preview {
    DeviceDiscoveryView()
        .environmentObject(DeviceDiscoveryManager.shared)
}
```

### 快捷键
- `⌘R` - 运行
- `⌘B` - 构建
- `⌘U` - 运行测试
- `⌘I` - Profile (性能分析)
- `⌘.` - 停止

### 日志查看

```bash
# 实时查看日志
log stream --predicate 'subsystem == "com.skybridge.compass.ios"' --level debug
```

## 🎊 完成！

现在你已经成功设置并运行了 SkyBridge Compass iOS！

**享受跨平台的安全设备管理体验！**

---

需要帮助？查看完整文档或访问 [GitHub Issues](https://github.com/billlza/Skybridge-Compass/issues)
