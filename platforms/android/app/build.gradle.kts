plugins {
    id("com.android.application")
    id("com.google.devtools.ksp")
    id("dagger.hilt.android.plugin")
    id("org.jetbrains.kotlin.plugin.serialization")
    // Kotlin 2.0+ Compose Gradle 插件（Android Compose 必需）
    id("org.jetbrains.kotlin.plugin.compose")
}

import java.util.Properties

// 加载 Supabase 配置（优先 local.properties，其次环境变量，最后回退到当前占位值）
val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) {
        load(f.inputStream())
    }
}
val SUPABASE_URL_PROP: String? = localProps.getProperty("SUPABASE_URL") ?: System.getenv("SUPABASE_URL")
val SUPABASE_ANON_KEY_PROP: String? = localProps.getProperty("SUPABASE_ANON_KEY") ?: System.getenv("SUPABASE_ANON_KEY")
val GOOGLE_WEB_CLIENT_ID_PROP: String? = localProps.getProperty("GOOGLE_WEB_CLIENT_ID") ?: System.getenv("GOOGLE_WEB_CLIENT_ID")

// 规范最终值，避免在 buildTypes 内写复杂内插和转义
val SUPABASE_URL_FINAL = SUPABASE_URL_PROP ?: "https://hloqytmhjludmuhwyyzb.supabase.co"
val SUPABASE_ANON_KEY_FINAL = SUPABASE_ANON_KEY_PROP ?: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb3F5dG1oamx1ZG11aHd5eXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUzNTE3ODUsImV4cCI6MjA3MDkyNzc4NX0.xmDCgBo5IpDlzIerIz7y2jruh34MEYrtcepeK3x_HT0"
val GOOGLE_WEB_CLIENT_ID_FINAL = GOOGLE_WEB_CLIENT_ID_PROP ?: ""



android {
    namespace = "com.skybridge.compass"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.skybridge.compass"
        minSdk = 33
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"

        testInstrumentationRunner = "com.skybridge.compass.android.HiltTestRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            // Emulator默认连接宿主机：10.0.2.2
            buildConfigField("String", "API_BASE_URL", "\"http://10.0.2.2:8080/api/\"")
            buildConfigField("boolean", "ENABLE_LOGGING", "true")
            buildConfigField("boolean", "ENABLE_PERFORMANCE_MONITORING", "true")
            buildConfigField("String", "SUPABASE_URL", "\"${SUPABASE_URL_FINAL}\"")
            buildConfigField("String", "SUPABASE_ANON_KEY", "\"${SUPABASE_ANON_KEY_FINAL}\"")
            buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"${GOOGLE_WEB_CLIENT_ID_FINAL}\"")
            isMinifyEnabled = false
            isDebuggable = true
        }
        
        release {
            buildConfigField("String", "API_BASE_URL", "\"https://api.skybridge.com/\"")
            buildConfigField("boolean", "ENABLE_LOGGING", "false")
            buildConfigField("boolean", "ENABLE_PERFORMANCE_MONITORING", "false")
            buildConfigField("String", "SUPABASE_URL", "\"${SUPABASE_URL_FINAL}\"")
            buildConfigField("String", "SUPABASE_ANON_KEY", "\"${SUPABASE_ANON_KEY_FINAL}\"")
            buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"${GOOGLE_WEB_CLIENT_ID_FINAL}\"")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        
        create("staging") {
            initWith(getByName("debug"))
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            buildConfigField("String", "API_BASE_URL", "\"https://staging-api.skybridge.com/\"")
            buildConfigField("boolean", "ENABLE_LOGGING", "true")
            buildConfigField("boolean", "ENABLE_PERFORMANCE_MONITORING", "true")
            buildConfigField("String", "SUPABASE_URL", "\"${SUPABASE_URL_FINAL}\"")
            buildConfigField("String", "SUPABASE_ANON_KEY", "\"${SUPABASE_ANON_KEY_FINAL}\"")
            buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"${GOOGLE_WEB_CLIENT_ID_FINAL}\"")
            isMinifyEnabled = false
            isDebuggable = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        buildConfig = true
        compose = true
    }

    // 使用 Kotlin Compose 插件后不再需要 legacy 的 composeOptions
    // composeOptions {
    //     kotlinCompilerExtensionVersion = "1.5.13"
    // }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        freeCompilerArgs.add("-Xannotation-default-target=param-property")
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":device-discovery"))
    implementation(project(":remote-control"))
    implementation(project(":file-transfer"))
    implementation(project(":shared"))

    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.profileinstaller:profileinstaller:1.4.1")
    configurations.all {
        resolutionStrategy {
            force("androidx.browser:browser:1.9.0")
        }
    }
    
    // Compose BOM
    implementation(platform("androidx.compose:compose-bom:2026.03.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.navigation:navigation-compose:2.9.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    // Add missing Compose integrations
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.fragment:fragment-ktx:1.8.9")
    // Avatar loading
    implementation("io.coil-kt:coil-compose:2.7.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    
    // Hilt
    implementation("com.google.dagger:hilt-android:2.59.2")
    implementation("androidx.hilt:hilt-navigation-compose:1.3.0")
    ksp("com.google.dagger:hilt-compiler:2.59.2")
    
    // Network
    implementation("com.squareup.retrofit2:retrofit:3.0.0")
    implementation("com.squareup.retrofit2:converter-gson:3.0.0")
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    implementation("com.squareup.okhttp3:logging-interceptor:5.3.2")
    
    // Ktor
    implementation("io.ktor:ktor-client-core:3.4.1")
    implementation("io.ktor:ktor-client-okhttp:3.4.1")
    implementation("io.ktor:ktor-client-content-negotiation:3.4.1")
    implementation("io.ktor:ktor-client-logging:3.4.1")
    implementation("io.ktor:ktor-client-websockets:3.4.1")
    implementation("io.ktor:ktor-serialization-kotlinx-json:3.4.1")
    implementation("io.ktor:ktor-client-cio:3.4.1")
    
    // Supabase-kt BOM + modules
    implementation(platform("io.github.jan-tennert.supabase:bom:3.4.1"))
    implementation("io.github.jan-tennert.supabase:supabase-kt")
    implementation("io.github.jan-tennert.supabase:auth-kt")
    implementation("io.github.jan-tennert.supabase:postgrest-kt")
    implementation("io.github.jan-tennert.supabase:storage-kt")
    implementation("io.github.jan-tennert.supabase:realtime-kt")
    
    // Serialization
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.10.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    // WorkManager
    implementation("androidx.work:work-runtime-ktx:2.11.1")

    // Room (needed due to AppDatabase type usage from core)
    implementation("androidx.room:room-ktx:2.8.4")

    // Security (EncryptedSharedPreferences for secure account storage)
    implementation("androidx.security:security-crypto:1.1.0")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("com.google.android.gms:play-services-auth:21.5.1")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("io.mockk:mockk:1.14.9")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:rules:1.7.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.03.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.navigation:navigation-testing:2.9.7")
    androidTestImplementation("com.google.dagger:hilt-android-testing:2.59.2")
    kspAndroidTest("com.google.dagger:hilt-compiler:2.59.2")
    
    // Debug Tools
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    debugImplementation("com.squareup.leakcanary:leakcanary-android:2.14")
    // DataStore Preferences for persistent developer settings
    implementation("androidx.datastore:datastore-preferences:1.2.1")
}

tasks.register("locateDebugArtifacts") {
    group = "verification"
    description = "Print expected paths of debug APK/AAB and existence"
    doLast {
        val apkDir = layout.buildDirectory.dir("outputs/apk/debug").get().asFile
        val aabDir = layout.buildDirectory.dir("outputs/bundle/debug").get().asFile
        println("APK Debug Dir: ${apkDir.absolutePath}, exists=${apkDir.exists()}")
        println("AAB Debug Dir: ${aabDir.absolutePath}, exists=${aabDir.exists()}")
    }
}

// Attach output logging to key packaging tasks
tasks.register("printTaskOutputs") {
    group = "verification"
    description = "Print outputs.files of key packaging tasks"
    doLast {
        listOf(
            "packageDebug",
            "packageDebugUniversalApk",
            "bundleDebug",
            "signDebugBundle",
            "makeApkFromBundleForDebug",
            "zipApksForDebug"
        ).forEach { name ->
            val t = tasks.findByName(name)
            val outputsList = t?.outputs?.files?.files?.map { it.absolutePath } ?: emptyList()
            println("[$name] outputs.files: ${outputsList}")
        }
    }
}
