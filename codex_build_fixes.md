# CodeX 构建错误修复指南

## 当前构建错误分析

根据构建日志，主要错误包括：

### 1. AndroidManifest.xml 警告
```
package="com.yunqiao.sinan" found in source AndroidManifest.xml
Setting the namespace via the package attribute in the source AndroidManifest.xml is no longer supported
```

**修复方法**：
```bash
# 移除AndroidManifest.xml中的package属性
sed -i 's/package="com.yunqiao.sinan"//g' app/src/main/AndroidManifest.xml
```

### 2. Kotlin编译错误

#### 错误1: `Unresolved reference 'simulateStatusUpdate'`
**位置**: `DeviceStatusBar.kt:42:33`
**修复**: 注释掉或实现该函数

#### 错误2: `Smart cast to 'kotlin.Int' is impossible`
**位置**: `DeviceStatusBar.kt:123:34`
**修复**: 使用`.value`访问委托属性

#### 错误3: `Unresolved reference 'Cpu'`
**位置**: `MainControlScreen.kt:124:42`
**修复**: 使用完整的类名或导入

#### 错误4: `Function 'component1()' is ambiguous`
**位置**: `Node6DashboardScreen.kt:189:25`
**修复**: 明确指定类型或使用不同的解构方式

### 3. AndroidX配置错误
```
Configuration `:app:debugRuntimeClasspath` contains AndroidX dependencies, but the `android.useAndroidX` property is not enabled
```

**修复方法**：
在`gradle.properties`中添加：
```properties
android.useAndroidX=true
android.enableJetifier=true
```

## 自动修复脚本

```bash
#!/bin/bash
cd YunQiaoSiNan

# 1. 修复AndroidManifest.xml
sed -i 's/package="com.yunqiao.sinan"//g' app/src/main/AndroidManifest.xml

# 2. 修复gradle.properties
echo "android.useAndroidX=true" >> gradle.properties
echo "android.enableJetifier=true" >> gradle.properties

# 3. 修复Kotlin代码
# DeviceStatusBar.kt
sed -i 's/simulateStatusUpdate()/\/\/ simulateStatusUpdate() - 临时注释/g' app/src/main/java/com/yunqiao/sinan/ui/component/DeviceStatusBar.kt
sed -i 's/batteryLevel\.toInt()/batteryLevel.value.toInt()/g' app/src/main/java/com/yunqiao/sinan/ui/component/DeviceStatusBar.kt

# MainControlScreen.kt
sed -i 's/Cpu\./SystemInfo.Cpu./g' app/src/main/java/com/yunqiao/sinan/ui/screen/MainControlScreen.kt

# Node6DashboardScreen.kt
sed -i 's/val (cpu, memory, storage) = systemInfo/val (cpu, memory, storage) = systemInfo.toList()/g' app/src/main/java/com/yunqiao/sinan/ui/screen/Node6DashboardScreen.kt

# 4. 清理并重新构建
./gradlew clean
./gradlew assembleDebug
```

## 手动修复步骤

如果自动修复失败，可以手动修复：

1. **AndroidManifest.xml**: 移除`package="com.yunqiao.sinan"`属性
2. **gradle.properties**: 添加AndroidX配置
3. **Kotlin文件**: 根据错误信息逐个修复代码问题
4. **清理构建**: 运行`./gradlew clean`
5. **重新构建**: 运行`./gradlew assembleDebug`

## 预期结果

修复后应该能够成功构建APK文件，生成`app/build/outputs/apk/debug/app-debug.apk`。
