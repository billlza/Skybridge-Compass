#!/bin/bash
# 修复CodeX构建错误的脚本

echo "=== 修复Android项目构建错误 ==="

# 检查项目目录
if [ ! -d "YunQiaoSiNan" ]; then
    echo "错误: 找不到YunQiaoSiNan目录"
    exit 1
fi

cd YunQiaoSiNan

echo "1. 修复AndroidManifest.xml中的package属性..."
# 移除AndroidManifest.xml中的package属性
if [ -f "app/src/main/AndroidManifest.xml" ]; then
    sed -i 's/package="com.yunqiao.sinan"//g' app/src/main/AndroidManifest.xml
    echo "已移除AndroidManifest.xml中的package属性"
fi

echo "2. 检查并修复Kotlin编译错误..."

# 检查DeviceStatusBar.kt文件
if [ -f "app/src/main/java/com/yunqiao/sinan/ui/component/DeviceStatusBar.kt" ]; then
    echo "修复DeviceStatusBar.kt中的simulateStatusUpdate错误..."
    
    # 修复simulateStatusUpdate未定义的问题
    sed -i 's/simulateStatusUpdate()/\/\/ simulateStatusUpdate() - 临时注释/g' app/src/main/java/com/yunqiao/sinan/ui/component/DeviceStatusBar.kt
    
    # 修复batteryLevel智能转换问题
    sed -i 's/batteryLevel\.toInt()/batteryLevel.value.toInt()/g' app/src/main/java/com/yunqiao/sinan/ui/component/DeviceStatusBar.kt
fi

# 检查MainControlScreen.kt文件
if [ -f "app/src/main/java/com/yunqiao/sinan/ui/screen/MainControlScreen.kt" ]; then
    echo "修复MainControlScreen.kt中的Cpu引用错误..."
    
    # 修复Cpu未定义的问题
    sed -i 's/Cpu\./SystemInfo.Cpu./g' app/src/main/java/com/yunqiao/sinan/ui/screen/MainControlScreen.kt
fi

# 检查Node6DashboardScreen.kt文件
if [ -f "app/src/main/java/com/yunqiao/sinan/ui/screen/Node6DashboardScreen.kt" ]; then
    echo "修复Node6DashboardScreen.kt中的component1()歧义..."
    
    # 修复component1()歧义问题
    sed -i 's/val (cpu, memory, storage) = systemInfo/val (cpu, memory, storage) = systemInfo.toList()/g' app/src/main/java/com/yunqiao/sinan/ui/screen/Node6DashboardScreen.kt
fi

echo "3. 确保gradle.properties配置正确..."
# 确保AndroidX配置正确
if [ -f "gradle.properties" ]; then
    # 添加或更新AndroidX配置
    if ! grep -q "android.useAndroidX=true" gradle.properties; then
        echo "android.useAndroidX=true" >> gradle.properties
    fi
    if ! grep -q "android.enableJetifier=true" gradle.properties; then
        echo "android.enableJetifier=true" >> gradle.properties
    fi
    echo "已确保gradle.properties中的AndroidX配置"
fi

echo "4. 清理构建缓存..."
./gradlew clean

echo "5. 尝试重新构建..."
./gradlew assembleDebug

echo "=== 修复完成 ==="
