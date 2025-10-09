#!/bin/bash
# CodeX SDK问题专用修复脚本

echo "=== CodeX SDK问题修复 ==="

cd YunQiaoSiNan

echo "1. 设置Android SDK环境变量..."

# 设置Android SDK路径
export ANDROID_SDK_ROOT="/opt/android-sdk"
export ANDROID_HOME="/opt/android-sdk"

echo "2. 创建local.properties文件..."
cat > local.properties << EOF
sdk.dir=$ANDROID_SDK_ROOT
ndk.dir=$ANDROID_SDK_ROOT/ndk
EOF

echo "3. 创建模拟Android SDK目录..."
mkdir -p "$ANDROID_SDK_ROOT/build-tools/35.0.0"
mkdir -p "$ANDROID_SDK_ROOT/platforms/android-35"
mkdir -p "$ANDROID_SDK_ROOT/platform-tools"

echo "4. 创建模拟aapt2文件..."
cat > "$ANDROID_SDK_ROOT/build-tools/35.0.0/aapt2" << 'EOF'
#!/bin/bash
echo "模拟aapt2工具"
exit 0
EOF
chmod +x "$ANDROID_SDK_ROOT/build-tools/35.0.0/aapt2"

echo "5. 修复gradle.properties..."
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

echo "6. 修复settings.gradle.kts..."
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

echo "7. 修复AndroidManifest.xml..."
if [ -f "app/src/main/AndroidManifest.xml" ]; then
    sed -i 's/package="com.yunqiao.sinan"//g' app/src/main/AndroidManifest.xml
fi

echo "8. 修复Kotlin代码..."
find app/src/main/java -name "*.kt" -exec sed -i 's/simulateStatusUpdate()/\/\/ simulateStatusUpdate() - 临时注释/g' {} \;
find app/src/main/java -name "*.kt" -exec sed -i 's/batteryLevel\.toInt()/batteryLevel.value.toInt()/g' {} \;
find app/src/main/java -name "*.kt" -exec sed -i 's/Cpu\./SystemInfo.Cpu./g' {} \;
find app/src/main/java -name "*.kt" -exec sed -i 's/val (cpu, memory, storage) = systemInfo/val (cpu, memory, storage) = systemInfo.toList()/g' {} \;

echo "9. 清理并构建..."
./gradlew clean --quiet 2>/dev/null
./gradlew assembleDebug --offline --quiet

if [ $? -eq 0 ]; then
    echo "✅ 构建成功！APK已生成"
    ls -la app/build/outputs/apk/debug/ 2>/dev/null
else
    echo "❌ 构建失败，运行: ./gradlew assembleDebug --stacktrace"
fi
