# SkyBridge Compass - Android应用

> Portability branch snapshot: `Bill/android-portability`
>
> Branch-specific references:
> - [BUILD.md](BUILD.md)
> - [STATUS.md](STATUS.md)
> - [PORTABILITY_IMPORT.md](PORTABILITY_IMPORT.md)

SkyBridge Compass是一个跨平台设备连接和控制应用的Android客户端，提供设备发现、屏幕镜像、远程控制和文件传输功能。

## 功能特性

### 🔍 设备发现
- 自动扫描局域网内的可连接设备
- 支持多种设备类型（iOS、Android、Windows、macOS）
- 实时设备状态监控
- 智能设备分类和过滤

### 📱 屏幕镜像
- 高质量屏幕投射
- 可调节镜像质量和帧率
- 支持横屏和竖屏模式
- 低延迟传输优化

### 🎮 远程控制
- 触摸手势映射
- 键盘输入支持
- 鼠标操作模拟
- 多点触控支持

### 📁 文件传输
- 拖拽式文件传输
- 批量文件操作
- 传输进度监控
- 断点续传支持

### 🎨 现代化UI
- Material Design 3设计语言
- 响应式布局适配
- 深色模式支持
- 流畅的动画效果

## 技术架构

### 核心技术栈
- **Kotlin** - 主要开发语言
- **Jetpack Compose** - 现代化UI框架
- **Hilt** - 依赖注入框架
- **Room** - 本地数据库
- **Retrofit** - 网络请求库
- **Coroutines** - 异步编程

### 架构模式
- **MVVM** - Model-View-ViewModel架构
- **Repository Pattern** - 数据访问层抽象
- **Clean Architecture** - 分层架构设计
- **Dependency Injection** - 依赖注入模式

### 项目结构
```
app/
├── src/
│   ├── main/
│   │   ├── kotlin/com/skybridge/compass/android/
│   │   │   ├── ui/                    # UI层
│   │   │   │   ├── screens/           # 屏幕组件
│   │   │   │   ├── components/        # 通用UI组件
│   │   │   │   ├── navigation/        # 导航配置
│   │   │   │   └── theme/             # 主题配置
│   │   │   ├── data/                  # 数据层
│   │   │   │   ├── repository/        # 仓库实现
│   │   │   │   ├── local/             # 本地数据源
│   │   │   │   └── remote/            # 远程数据源
│   │   │   ├── domain/                # 业务逻辑层
│   │   │   │   ├── usecase/           # 用例
│   │   │   │   └── model/             # 领域模型
│   │   │   ├── di/                    # 依赖注入配置
│   │   │   └── utils/                 # 工具类
│   │   └── res/                       # 资源文件
│   ├── test/                          # 单元测试
│   └── androidTest/                   # UI测试
└── build.gradle.kts                   # 构建配置
```

## 当前可移植性快照

- 分支用途：Android portability snapshot / cloud backup
- 当前导入目录：`platforms/android`
- 推荐构建入口：`./gradlew :app:assembleDebug --warning-mode all`
- 当前 Android 配置：
  - `compileSdk = 36`
  - `targetSdk = 36`
  - `minSdk = 33`
  - Kotlin / AGP 基线见根 [build.gradle.kts](build.gradle.kts) 和 [app/build.gradle.kts](app/build.gradle.kts)
- 当前原生依赖：
  - `shared` 模块使用 `externalNativeBuild`
  - 预编译 `liboqs` 头文件和静态库位于 `shared/libs/liboqs`

## 开发环境要求

### 必需软件
- Android Studio 或兼容的 Android Gradle 构建环境
- JDK 21
- Android SDK Platform 36
- Android NDK 和 CMake 3.22.1（`shared` 原生构建需要）

### 本地配置
- `local.properties` 不进入版本控制
- `local.properties` 或环境变量可提供：
  - `SUPABASE_URL`
  - `SUPABASE_ANON_KEY`
  - `GOOGLE_WEB_CLIENT_ID`
- 构建也会使用开发机上的 Android SDK 路径信息，因此建议每台机器单独维护 `local.properties`

## 快速开始

### 1. 打开 portability 快照
```bash
cd platforms/android
```

### 2. 调试构建
```bash
./gradlew :app:assembleDebug --warning-mode all
```

### 3. 安装到设备
```bash
./gradlew :app:installDebug
```

### 4. 常用验证
```bash
./gradlew test
./gradlew connectedDebugAndroidTest
```

## 构建配置

### 构建变体
- **debug** - 开发调试版本
  - 启用日志输出
  - 启用性能监控
  - 连接本地开发服务器
  
- **staging** - 预发布测试版本
  - 启用日志输出
  - 启用性能监控
  - 连接测试服务器
  
- **release** - 生产发布版本
  - 禁用日志输出
  - 禁用性能监控
  - 连接生产服务器
  - 启用代码混淆

### 环境变量配置
```bash
# 发布签名配置
export KEYSTORE_PASSWORD="your_keystore_password"
export KEY_ALIAS="your_key_alias"
export KEY_PASSWORD="your_key_password"
```

### 构建命令
```bash
# 推荐的 portability 构建命令
./gradlew :app:assembleDebug --warning-mode all

# 其他常用构建
./gradlew :app:installDebug
./gradlew :app:assembleRelease
./gradlew syncBaselineProfiles
```

## 测试

### 单元测试
```bash
# 运行所有单元测试
./gradlew test

# 运行特定测试类
./gradlew test --tests "DeviceDiscoveryRepositoryTest"

# 生成测试报告
./gradlew testDebugUnitTest
```

### UI测试
```bash
# 运行所有UI测试
./gradlew connectedDebugAndroidTest

# 运行特定测试
./gradlew connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.skybridge.compass.android.DashboardScreenTest
```

## 代码质量

### 静态分析
```bash
# 运行Lint检查
./gradlew :app:lintDebug
```

## 性能优化

### 内存优化
- 使用LeakCanary检测内存泄漏
- 实现自定义性能监控
- 优化图片加载和缓存

### 网络优化
- 实现请求缓存机制
- 使用连接池优化
- 支持离线模式

### UI优化
- 使用Compose性能最佳实践
- 实现懒加载和虚拟化
- 优化重组性能

## 部署

### 内部测试
1. 构建staging版本
2. 上传到内部测试平台
3. 进行功能和性能测试

### 生产发布
1. 更新版本号和变更日志
2. 构建release版本
3. 进行最终测试
4. 上传到Google Play Console
5. 发布到生产环境

## 故障排除

### 常见问题

**Q: Gradle同步失败**
A: 检查网络连接，清理Gradle缓存：`./gradlew clean`

**Q: 应用无法连接到服务器**
A: 检查网络权限，确认服务器地址配置正确

**Q: 测试运行失败**
A: 确保测试设备已连接，检查测试权限配置

**Q: 构建速度慢**
A: 启用Gradle并行构建，增加JVM堆内存大小

### 调试技巧
- 使用Android Studio的调试器
- 查看Logcat输出
- 使用网络抓包工具
- 启用开发者选项

## 贡献指南

### 开发流程
1. Fork项目到个人仓库
2. 创建功能分支
3. 提交代码变更
4. 创建Pull Request
5. 代码审查和合并

### 代码规范
- 遵循Kotlin编码规范
- 使用有意义的变量和函数名
- 添加适当的注释和文档
- 编写单元测试

### 提交规范
```
type(scope): description

[optional body]

[optional footer]
```

类型：
- `feat`: 新功能
- `fix`: 错误修复
- `docs`: 文档更新
- `style`: 代码格式
- `refactor`: 重构
- `test`: 测试相关
- `chore`: 构建过程或辅助工具的变动

## 许可证

本项目采用MIT许可证，详见[LICENSE](LICENSE)文件。

## 联系方式

- **项目主页**: https://github.com/your-org/skybridge-compass
- **问题反馈**: https://github.com/your-org/skybridge-compass/issues
- **邮箱**: support@skybridge-compass.com

## 更新日志

### v1.0.0 (2024-01-XX)
- 🎉 首次发布
- ✨ 实现设备发现功能
- ✨ 实现屏幕镜像功能
- ✨ 实现远程控制功能
- ✨ 实现文件传输功能
- 🎨 现代化UI设计
- 📱 响应式布局支持
- 🧪 完整的测试覆盖
- 📚 详细的文档说明
