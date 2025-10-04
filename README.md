# SkyBridge Compass (云桥司南)

现代化的 Android 应用，集成天气、设备管理、远程桌面等功能。

## 技术栈

- **Gradle**: 9.0.0 (最新版本)
- **Java**: 21 LTS (支持 Java 25 LTS)
- **Kotlin**: 2.0.20
- **Android Gradle Plugin**: 8.7.3
- **Compose**: 2024.12.01
- **Target SDK**: 35
- **Min SDK**: 24

## 快速开始

### 环境要求

- Java 17+ (推荐 Java 21 LTS)
- Android Studio Hedgehog 2023.1.1+
- Gradle 9.0.0

### 构建项目

```bash
# 克隆仓库
git clone https://github.com/billlza/Skybridge-Compass.git
cd Skybridge-Compass

# 设置 Java 环境 (可选)
./setup-java.sh

# 构建项目
./gradlew clean build

# 运行测试
./gradlew test

# 生成 APK
./gradlew assembleDebug
```

### 验证环境

```bash
# 检查 Gradle 版本
./gradlew --version

# 验证项目配置
./verify-repo.sh
```

## 项目结构

```
app/
├── src/main/java/com/yunqiao/sinan/
│   ├── MainActivity.kt                 # 主活动
│   ├── data/                           # 数据模型
│   ├── manager/                        # 管理器
│   ├── node6/                          # Node 6 功能模块
│   ├── ui/                             # UI 组件
│   └── weather/                        # 天气功能
└── build.gradle.kts                    # 应用构建配置

gradle/
└── wrapper/                           # Gradle Wrapper
    ├── gradle-wrapper.jar
    └── gradle-wrapper.properties

gradlew                                # Gradle Wrapper 脚本
gradlew.bat                           # Windows 批处理脚本
build.gradle.kts                      # 项目构建配置
settings.gradle.kts                   # 项目设置
gradle.properties                     # Gradle 属性配置
```

## 功能特性

- 🌤️ **天气中心**: 实时天气数据和壁纸
- 🖥️ **远程桌面**: WebRTC 和 QUIC 支持
- 📱 **设备管理**: 设备发现和连接管理
- 📁 **文件传输**: P2P 文件传输
- 🤖 **AI 助手**: 智能对话功能
- 🎨 **现代化 UI**: Material Design 3

## 开发指南

### 代码规范

- 使用 Kotlin 官方代码风格
- 遵循 Android 开发最佳实践
- 使用 Compose 构建 UI

### 构建优化

- 启用并行构建 (`org.gradle.parallel=true`)
- 使用 G1 垃圾收集器
- 配置 4GB 堆内存

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request！

---

**注意**: 本项目使用最新的 Gradle 9.0.0 和 Java 21 LTS，确保开发环境兼容。
