# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Uncomment this to preserve the line number information for
# debugging stack traces.
#-keepattributes SourceFile,LineNumberTable

# If you keep the line number information, uncomment this to
# hide the original source file name.
#-renamesourcefileattribute SourceFile

# === ARM64优化和Android 13-15适配规则 ===

# Keep Kotlin classes
-keep class kotlin.** { *; }
-keep class kotlinx.** { *; }
-dontwarn kotlin.**
-dontwarn kotlinx.**

# Keep Compose classes - Android 15兼容
-keep class androidx.compose.** { *; }
-keep class androidx.compose.runtime.** { *; }
-keep class androidx.compose.ui.** { *; }
-keep class androidx.compose.foundation.** { *; }
-keep class androidx.compose.material3.** { *; }
-dontwarn androidx.compose.**

# Lifecycle and ViewModel - Android 14+适配
-keep class androidx.lifecycle.** { *; }
-keep class androidx.lifecycle.viewmodel.** { *; }
-dontwarn androidx.lifecycle.**

# Navigation Compose
-keep class androidx.navigation.** { *; }
-dontwarn androidx.navigation.**

# Network libraries - 保持网络相关类
-keep class retrofit2.** { *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-dontwarn retrofit2.**
-dontwarn okhttp3.**
-dontwarn okio.**

# Gson/Kotlinx Serialization
-keep class kotlinx.serialization.** { *; }
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# Keep all model/data classes
-keep class com.yunqiao.sinan.data.** { *; }
-keep class com.yunqiao.sinan.node6.model.** { *; }
-keep class com.yunqiao.sinan.shared.** { *; }

# Keep managers and services
-keep class com.yunqiao.sinan.manager.** { *; }
-keep class com.yunqiao.sinan.node6.manager.** { *; }
-keep class com.yunqiao.sinan.node6.service.** { *; }
-keep class com.yunqiao.sinan.weather.** { *; }

# Accompanist库优化
-keep class com.google.accompanist.** { *; }
-dontwarn com.google.accompanist.**

# Coil图像加载
-keep class coil.** { *; }
-dontwarn coil.**

# Android权限相关 - Android 13+
-keep class androidx.core.app.** { *; }
-keep class androidx.activity.** { *; }
-dontwarn androidx.core.app.**
-dontwarn androidx.activity.**

# 保持反射调用的类
-keepattributes *Annotation*
-keepclassmembers class * {
    @androidx.compose.runtime.Composable <methods>;
}

# 保持enum类
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# 移除日志(Release版本)
-assumenosideeffects class android.util.Log {
    public static *** d(...);
    public static *** v(...);
    public static *** i(...);
}

# 激进优化选项 - ARM64专用
-optimizations !code/simplification/arithmetic,!code/simplification/cast,!field/*,!class/merging/*
-optimizationpasses 5
-allowaccessmodification
-dontpreverify

# 保持Native方法
-keepclasseswithmembernames class * {
    native <methods>;
}

# 保持Parcelable
-keepclassmembers class * implements android.os.Parcelable {
  public static final android.os.Parcelable$Creator CREATOR;
}

# ARM64 JNI优化
-keepclasseswithmembernames class * {
    native <methods>;
}
-keep class * extends java.lang.annotation.Annotation { *; }

# 压缩优化
-repackageclasses ''
-allowaccessmodification