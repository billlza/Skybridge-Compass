# 云桥司南离线构建工具包

## 概述
这个工具包包含了在 CodeX 等无网络环境下构建 Android APK 所需的所有组件。

## 包含内容
- `gradle/` - Gradle Wrapper 文件
- `gradlew` - Gradle Wrapper 脚本 (Unix/Linux/macOS)
- `gradlew.bat` - Gradle Wrapper 脚本 (Windows)
- `offline-build.sh` - 离线构建脚本

## 使用方法

### 1. 环境要求
- Java 21 LTS
- Android SDK (API 35)
- 无网络环境

### 2. 构建步骤
```bash
# 进入项目根目录
cd /path/to/project

# 复制工具包到项目根目录
cp -r offline-build-tools/* .

# 设置执行权限
chmod +x gradlew offline-build.sh

# 运行离线构建
./offline-build.sh
```

### 3. 手动构建
```bash
# 设置环境变量
export JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home
export ANDROID_HOME=/path/to/android/sdk

# 执行构建
./gradlew assembleDebug --offline --console=plain
```

## 注意事项
- 确保所有依赖已预下载到本地缓存
- 构建过程中不会访问网络
- 适用于 CodeX 等受限环境

## 故障排除
如果构建失败，请检查：
1. Java 环境是否正确配置
2. Android SDK 路径是否正确
3. 项目依赖是否完整
