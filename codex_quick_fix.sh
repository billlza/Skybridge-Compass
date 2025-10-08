#!/bin/bash
# CodeX快速修复脚本

echo "=== CodeX构建错误快速修复 ==="

cd YunQiaoSiNan

echo "1. 修复AndroidManifest.xml..."
if [ -f "app/src/main/AndroidManifest.xml" ]; then
    sed -i 's/package="com.yunqiao.sinan"//g' app/src/main/AndroidManifest.xml
    echo "✓ 已移除package属性"
fi

echo "2. 修复gradle.properties..."
if [ -f "gradle.properties" ]; then
    if ! grep -q "android.useAndroidX=true" gradle.properties; then
        echo "android.useAndroidX=true" >> gradle.properties
    fi
    if ! grep -q "android.enableJetifier=true" gradle.properties; then
        echo "android.enableJetifier=true" >> gradle.properties
    fi
    echo "✓ 已添加AndroidX配置"
fi

echo "3. 修复Kotlin编译错误..."

# 修复DeviceStatusBar.kt
if [ -f "app/src/main/java/com/yunqiao/sinan/ui/component/DeviceStatusBar.kt" ]; then
    # 注释掉simulateStatusUpdate调用
    sed -i 's/simulateStatusUpdate()/\/\/ simulateStatusUpdate() - 临时注释/g' app/src/main/java/com/yunqiao/sinan/ui/component/DeviceStatusBar.kt
    
    # 修复batteryLevel智能转换
    sed -i 's/batteryLevel\.toInt()/batteryLevel.value.toInt()/g' app/src/main/java/com/yunqiao/sinan/ui/component/DeviceStatusBar.kt
    echo "✓ 已修复DeviceStatusBar.kt"
fi

# 修复MainControlScreen.kt
if [ -f "app/src/main/java/com/yunqiao/sinan/ui/screen/MainControlScreen.kt" ]; then
    # 修复Cpu引用
    sed -i 's/Cpu\./SystemInfo.Cpu./g' app/src/main/java/com/yunqiao/sinan/ui/screen/MainControlScreen.kt
    echo "✓ 已修复MainControlScreen.kt"
fi

# 修复Node6DashboardScreen.kt
if [ -f "app/src/main/java/com/yunqiao/sinan/ui/screen/Node6DashboardScreen.kt" ]; then
    # 修复component1()歧义
    sed -i 's/val (cpu, memory, storage) = systemInfo/val (cpu, memory, storage) = systemInfo.toList()/g' app/src/main/java/com/yunqiao/sinan/ui/screen/Node6DashboardScreen.kt
    echo "✓ 已修复Node6DashboardScreen.kt"
fi

echo "4. 清理构建缓存..."
./gradlew clean --quiet

echo "5. 尝试构建APK..."
./gradlew assembleDebug --quiet

if [ $? -eq 0 ]; then
    echo "✅ 构建成功！APK文件已生成"
    echo "APK位置: app/build/outputs/apk/debug/app-debug.apk"
else
    echo "❌ 构建失败，请检查错误信息"
    echo "运行以下命令查看详细错误："
    echo "./gradlew assembleDebug --stacktrace"
fi

echo "=== 修复完成 ==="
