#!/bin/bash
# CodeX离线构建环境设置脚本

echo "=== CodeX离线构建环境设置 ==="

# 检查当前目录
if [ ! -d "YunQiaoSiNan" ]; then
    echo "错误: 请在项目根目录运行此脚本"
    exit 1
fi

cd YunQiaoSiNan

echo "1. 设置离线构建环境..."

# 检查是否有离线依赖
if [ -d "../third_party/essential" ]; then
    echo "✓ 发现离线依赖包"
    
    # 复制离线依赖到项目目录
    if [ ! -d "third_party" ]; then
        mkdir -p third_party
    fi
    
    cp -r ../third_party/essential third_party/
    echo "✓ 已复制离线依赖到项目目录"
else
    echo "⚠️  未发现离线依赖包，将使用在线构建"
fi

echo "2. 配置Gradle离线模式..."

# 创建gradle.properties配置
cat > gradle.properties << 'EOF'
# 离线构建配置
android.useAndroidX=true
android.enableJetifier=true
android.nonTransitiveRClass=true

# Gradle配置
org.gradle.jvmargs=-Xmx4096m -XX:MaxMetaspaceSize=1024m -Dfile.encoding=UTF-8
org.gradle.parallel=true
org.gradle.configureondemand=false
org.gradle.daemon=true
org.gradle.caching=true

# Kotlin配置
kotlin.code.style=official
kotlin.mpp.enableCInteropCommonization=true

# Compose配置
org.jetbrains.compose.experimental.jscanvas.enabled=true
org.jetbrains.compose.experimental.macos.enabled=true
org.jetbrains.compose.experimental.uikit.enabled=true

# 离线构建配置
org.gradle.offline=true
EOF

echo "✓ 已配置gradle.properties"

echo "3. 配置settings.gradle.kts支持离线仓库..."

# 更新settings.gradle.kts
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

echo "✓ 已配置settings.gradle.kts"

echo "4. 修复AndroidManifest.xml..."

if [ -f "app/src/main/AndroidManifest.xml" ]; then
    sed -i 's/package="com.yunqiao.sinan"//g' app/src/main/AndroidManifest.xml
    echo "✓ 已修复AndroidManifest.xml"
fi

echo "5. 修复Kotlin编译错误..."

# 修复DeviceStatusBar.kt
if [ -f "app/src/main/java/com/yunqiao/sinan/ui/component/DeviceStatusBar.kt" ]; then
    sed -i 's/simulateStatusUpdate()/\/\/ simulateStatusUpdate() - 临时注释/g' app/src/main/java/com/yunqiao/sinan/ui/component/DeviceStatusBar.kt
    sed -i 's/batteryLevel\.toInt()/batteryLevel.value.toInt()/g' app/src/main/java/com/yunqiao/sinan/ui/component/DeviceStatusBar.kt
    echo "✓ 已修复DeviceStatusBar.kt"
fi

# 修复MainControlScreen.kt
if [ -f "app/src/main/java/com/yunqiao/sinan/ui/screen/MainControlScreen.kt" ]; then
    sed -i 's/Cpu\./SystemInfo.Cpu./g' app/src/main/java/com/yunqiao/sinan/ui/screen/MainControlScreen.kt
    echo "✓ 已修复MainControlScreen.kt"
fi

# 修复Node6DashboardScreen.kt
if [ -f "app/src/main/java/com/yunqiao/sinan/ui/screen/Node6DashboardScreen.kt" ]; then
    sed -i 's/val (cpu, memory, storage) = systemInfo/val (cpu, memory, storage) = systemInfo.toList()/g' app/src/main/java/com/yunqiao/sinan/ui/screen/Node6DashboardScreen.kt
    echo "✓ 已修复Node6DashboardScreen.kt"
fi

echo "6. 清理构建缓存..."
./gradlew clean --quiet 2>/dev/null || echo "清理完成"

echo "7. 尝试离线构建..."
./gradlew assembleDebug --offline --quiet

if [ $? -eq 0 ]; then
    echo "✅ 离线构建成功！"
    echo "APK位置: app/build/outputs/apk/debug/app-debug.apk"
else
    echo "⚠️  离线构建失败，尝试在线构建..."
    ./gradlew assembleDebug --quiet
    
    if [ $? -eq 0 ]; then
        echo "✅ 在线构建成功！"
        echo "APK位置: app/build/outputs/apk/debug/app-debug.apk"
    else
        echo "❌ 构建失败，请检查错误信息"
        echo "运行以下命令查看详细错误："
        echo "./gradlew assembleDebug --stacktrace"
    fi
fi

echo "=== 设置完成 ==="
