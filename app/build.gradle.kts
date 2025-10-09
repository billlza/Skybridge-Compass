plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.yunqiao.sinan"
    compileSdk = 36 // Android 16 (API 36)

    defaultConfig {
        applicationId = "com.yunqiao.sinan"
        minSdk = 33  // Android 13.0+ 为最低支持版本
        targetSdk = 36   // Android 16 (API 36) 目标版本，与compileSdk保持一致
        versionCode = 11
        versionName = "2.11-permission-fix"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }

        ndk {
            // ARM64专用优化 - 移除其他架构支持
            abiFilters.addAll(listOf("arm64-v8a"))
        }
    }

    signingConfigs {
        create("release") {
            storeFile = file("YunQiaoSiNan-release.keystore")
            storePassword = "YunQiaoSiNan2025@Release"
            keyAlias = "YunQiaoSiNan"
            keyPassword = "YunQiaoSiNan2025@Release"
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
            enableV4Signing = true
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false // Disabled to prevent R8 build hang issue
            isShrinkResources = false // Also disabled
            isDebuggable = false
            signingConfig = signingConfigs.getByName("release")
            
            // R8全模式优化
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            
            // ARM64性能优化
            ndk {
                debugSymbolLevel = "NONE"
            }
            
            // APK优化配置
            isJniDebuggable = false
        }
        debug {
            isMinifyEnabled = false
            isShrinkResources = false
            isDebuggable = true
            applicationIdSuffix = ".debug"
            
            ndk {
                debugSymbolLevel = "FULL"
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "21"
        freeCompilerArgs += listOf(
            "-opt-in=androidx.compose.material3.ExperimentalMaterial3Api",
            "-opt-in=androidx.compose.foundation.ExperimentalFoundationApi",
            "-opt-in=androidx.compose.animation.ExperimentalAnimationApi"
        )
    }

    buildFeatures {
        compose = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.15"
    }
    
    // Android 13-16性能优化配置
    bundle {
        language {
            enableSplit = false  // 简化语言包
        }
        density {
            enableSplit = false  // 简化密度包
        }
        abi {
            enableSplit = false  // ARM64单一架构
        }
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
            excludes += "/META-INF/{DEPENDENCIES,LICENSE,LICENSE.txt,license.txt,NOTICE,NOTICE.txt,notice.txt}"
            
            // === ARM64专用优化 - 排除非目标架构 ===
            
            // 1. 排除所有非ARM64架构的JNI库
            excludes += "**/x86/**"
            excludes += "**/x86_64/**"
            excludes += "**/armeabi/**"
            excludes += "**/armeabi-v7a/**"
            excludes += "**/mips/**"
            excludes += "**/mips64/**"
            
            // 2. 排除所有桌面平台文件
            excludes += "**/macosx-*/**"
            excludes += "**/windows-*/**"
            excludes += "**/linux-*/**"
            excludes += "**/*.dylib"
            excludes += "**/*.dll"
            excludes += "**/*.exe"
            
            // 3. 排除ByteDeco大型库(非ARM64)
            excludes += "org/bytedeco/ffmpeg/linux-*/**"
            excludes += "org/bytedeco/ffmpeg/windows-*/**" 
            excludes += "org/bytedeco/ffmpeg/macosx-*/**"
            excludes += "org/bytedeco/openblas/**"  // 完全不需要
            excludes += "org/bytedeco/opencv/**"   // 完全不需要
            excludes += "org/bytedeco/librealsense2/**"
            
            // 4. 排除不必要的资源文件
            excludes += "**/*.md"
            excludes += "**/*.txt"
            excludes += "**/CHANGELOG*"
            excludes += "**/README*"
            excludes += "**/NOTICE*"
            excludes += "**/LICENSE*"
            
            // 5. 保留ARM64 Android必要的库
            pickFirsts += "**/arm64-v8a/libc++_shared.so"
            pickFirsts += "**/arm64-v8a/libfbjni.so"
            pickFirsts += "**/arm64-v8a/libglog.so"
            pickFirsts += "**/arm64-v8a/libreactnativejni.so"
            
        }
        
        // JNI优化配置 - Android 13+适配
        jniLibs {
            useLegacyPackaging = false
            keepDebugSymbols += "*/arm64-v8a/*.so"  // 保留ARM64调试信息
        }
    }
    
    // 设置APK输出名称
    applicationVariants.all {
        val variant = this
        variant.outputs
            .map { it as com.android.build.gradle.internal.api.BaseVariantOutputImpl }
            .forEach { output ->
                val outputFileName = "YunQiaoSiNan-ARM64-v${variant.versionName}-${variant.buildType.name}.apk"
                output.outputFileName = outputFileName
            }
    }
}

dependencies {
    // Core Android
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.security.crypto)
    
    // Compose BOM 版本管理
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.foundation)
    implementation(libs.androidx.foundation.layout)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    
    // Accompanist 更新到最新版本
    implementation(libs.accumpanist.systemuicontroller)
    implementation(libs.accumpanist.navigation.animation)
    
    // Coroutines
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.android)
    
    // Network
    implementation(libs.okhttp)
    implementation(libs.retrofit)
    
    // Image loading
    implementation(libs.coil.compose)
    
    // Desugaring 支持新Java API
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.3")
    
    // 运营枢纽专用依赖
    // Permission handling
    implementation("com.google.accompanist:accompanist-permissions:0.32.0")
    
    // Network utilities
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")
    
    // JSON processing
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.0")
    
    // File operations
    implementation("commons-io:commons-io:2.11.0")
    
    // Encryption 
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.ui.test.junit4)
    debugImplementation(libs.androidx.ui.tooling)
    debugImplementation(libs.androidx.ui.test.manifest)
}
