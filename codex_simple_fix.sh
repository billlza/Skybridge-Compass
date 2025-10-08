#!/bin/bash
# CodeX简单修复脚本

echo "=== CodeX简单修复 ==="

# 进入项目目录
cd YunQiaoSiNan

echo "1. 修复gradle.properties..."
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
EOF

echo "2. 修复settings.gradle.kts..."
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

echo "3. 修复AndroidManifest.xml..."
if [ -f "app/src/main/AndroidManifest.xml" ]; then
    sed -i 's/package="com.yunqiao.sinan"//g' app/src/main/AndroidManifest.xml
fi

echo "4. 修复Kotlin代码..."
find app/src/main/java -name "*.kt" -exec sed -i 's/simulateStatusUpdate()/\/\/ simulateStatusUpdate() - 临时注释/g' {} \;
find app/src/main/java -name "*.kt" -exec sed -i 's/batteryLevel\.toInt()/batteryLevel.value.toInt()/g' {} \;
find app/src/main/java -name "*.kt" -exec sed -i 's/Cpu\./SystemInfo.Cpu./g' {} \;
find app/src/main/java -name "*.kt" -exec sed -i 's/val (cpu, memory, storage) = systemInfo/val (cpu, memory, storage) = systemInfo.toList()/g' {} \;

echo "5. 清理并构建..."
./gradlew clean --quiet 2>/dev/null
./gradlew assembleDebug --quiet

if [ $? -eq 0 ]; then
    echo "✅ 构建成功！APK已生成"
    ls -la app/build/outputs/apk/debug/ 2>/dev/null
else
    echo "❌ 构建失败，运行: ./gradlew assembleDebug --stacktrace"
fi
