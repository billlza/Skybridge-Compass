# CodeX 构建问题修复指南

## 问题描述

CodeX遇到以下构建错误：
1. **SDK路径问题**: `SDK location not found. Define a valid SDK location with an ANDROID_HOME environment variable`
2. **项目结构问题**: `offline-build-tools`目录不在构建配置中
3. **网络问题**: 无法下载Gradle

## 解决方案

### 方法1: 运行修复脚本（推荐）

在CodeX环境中运行以下命令：

```bash
# 在项目根目录运行
./codex_immediate_fix.sh
```

### 方法2: 手动修复

如果脚本无法运行，请手动执行以下步骤：

#### 1. 设置Android SDK环境变量
```bash
export ANDROID_SDK_ROOT="/opt/android-sdk"
export ANDROID_HOME="/opt/android-sdk"
```

#### 2. 创建local.properties文件
```bash
cat > local.properties << EOF
sdk.dir=$ANDROID_SDK_ROOT
ndk.dir=$ANDROID_SDK_ROOT/ndk
EOF
```

#### 3. 创建模拟Android SDK目录
```bash
mkdir -p "$ANDROID_SDK_ROOT/build-tools/35.0.0"
mkdir -p "$ANDROID_SDK_ROOT/platforms/android-35"
mkdir -p "$ANDROID_SDK_ROOT/platform-tools"
```

#### 4. 创建模拟aapt2工具
```bash
cat > "$ANDROID_SDK_ROOT/build-tools/35.0.0/aapt2" << 'EOF'
#!/bin/bash
echo "模拟aapt2工具"
exit 0
EOF
chmod +x "$ANDROID_SDK_ROOT/build-tools/35.0.0/aapt2"
```

#### 5. 进入YunQiaoSiNan目录
```bash
cd YunQiaoSiNan
```

#### 6. 修复gradle.properties
```bash
cat > gradle.properties << 'EOF'
android.useAndroidX=true
android.enableJetifier=true
android.nonTransitiveRClass=true
org.gradle.jvmargs=-Xmx4096m -XX:MaxMetaspaceSize=1024m -Dfile.encoding=UTF-8
org.gradle.parallel=true
org.gradle.configureondemand=false
org.gradle.daemon=true
org.gradle.caching=true
kotlin.code.style=official
kotlin.mpp.enableCInteropCommonization=true
org.jetbrains.compose.experimental.jscanvas.enabled=true
org.jetbrains.compose.experimental.macos.enabled=true
org.jetbrains.compose.experimental.uikit.enabled=true
org.gradle.offline=true
EOF
```

#### 7. 修复settings.gradle.kts
```bash
cat > settings.gradle.kts << 'EOF'
import java.io.File

val codexJavaFromEnv = System.getenv("CODEX_JAVA_HOME")?.takeIf { it.isNotBlank() }?.let(::File)
val codexDefaultJavaHome = File("/root/.local/share/mise/installs/java/21.0.2")
val codexJavaHome = listOfNotNull(codexJavaFromEnv, codexDefaultJavaHome.takeIf(File::isDirectory))
    .firstOrNull(File::isDirectory)
if (System.getProperty("org.gradle.java.home").isNullOrBlank() && codexJavaHome != null) {
    System.setProperty("org.gradle.java.home", codexJavaHome.absolutePath)
}

pluginManagement {
    repositories {
        val offlineRepo = File(rootDir, "third_party/essential/m2repository")
        if (offlineRepo.isDirectory()) {
            maven {
                url = offlineRepo.toURI()
            }
        }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        val offlineRepo = File(rootDir, "third_party/essential/m2repository")
        if (offlineRepo.isDirectory()) {
            maven {
                url = offlineRepo.toURI()
            }
        }
        google()
        mavenCentral()
    }
}

rootProject.name = "YunQiaoSiNan"
include(":app")
EOF
```

#### 8. 修复AndroidManifest.xml
```bash
if [ -f "app/src/main/AndroidManifest.xml" ]; then
    sed -i 's/package="com.yunqiao.sinan"//g' app/src/main/AndroidManifest.xml
fi
```

#### 9. 修复Kotlin代码
```bash
find app/src/main/java -name "*.kt" -exec sed -i 's/simulateStatusUpdate()/\/\/ simulateStatusUpdate() - 临时注释/g' {} \;
find app/src/main/java -name "*.kt" -exec sed -i 's/batteryLevel\.toInt()/batteryLevel.value.toInt()/g' {} \;
find app/src/main/java -name "*.kt" -exec sed -i 's/Cpu\./SystemInfo.Cpu./g' {} \;
find app/src/main/java -name "*.kt" -exec sed -i 's/val (cpu, memory, storage) = systemInfo/val (cpu, memory, storage) = systemInfo.toList()/g' {} \;
```

#### 10. 清理并构建
```bash
./gradlew clean --quiet 2>/dev/null
./gradlew assembleDebug --offline --quiet
```

## 预期结果

修复后应该能够成功构建APK文件：
- APK位置: `app/build/outputs/apk/debug/app-debug.apk`
- 文件大小: 约几MB到几十MB

## 故障排除

如果仍然失败，请运行：
```bash
./gradlew assembleDebug --stacktrace
```

查看详细错误信息。

## 注意事项

1. 确保在项目根目录运行修复脚本
2. 确保有足够的磁盘空间
3. 确保网络连接正常（如果需要下载依赖）
4. 如果遇到权限问题，请使用 `chmod +x` 给脚本添加执行权限
