plugins {
    id("com.android.library")
    id("com.google.devtools.ksp")
    id("dagger.hilt.android.plugin")
    id("kotlin-parcelize")
    id("org.jetbrains.kotlin.plugin.serialization")
    // Kotlin 2.0+ Compose Gradle 插件（Android Compose 必需）
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.skybridge.compass.devicediscovery"
    compileSdk = 36

    defaultConfig {
        minSdk = 33

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        
        create("staging") {
            initWith(getByName("debug"))
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    lint {
        targetSdk = 36
    }

    // 使用 Kotlin Compose 插件后不再需要 legacy 的 composeOptions
    // composeOptions {
    //     kotlinCompilerExtensionVersion = "1.5.13"
    // }
    
    testOptions {
        targetSdk = 36
        unitTests.all {
            it.useJUnitPlatform()
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
    // Local modules
    implementation(project(":core"))
    
    // Core Android dependencies
    implementation("androidx.core:core-ktx:1.18.0")

    implementation("androidx.annotation:annotation:1.9.1")
    
    // Compose BOM
    implementation(platform("androidx.compose:compose-bom:2026.03.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    
    // Hilt for dependency injection
    implementation("com.google.dagger:hilt-android:2.59.2")
    ksp("com.google.dagger:hilt-compiler:2.59.2")
    
    // Ktor Client Dependencies
    implementation("io.ktor:ktor-client-core:3.4.1")
    implementation("io.ktor:ktor-client-android:3.4.1")
    implementation("io.ktor:ktor-client-websockets:3.4.1")
    implementation("io.ktor:ktor-client-logging:3.4.1")
    implementation("io.ktor:ktor-client-content-negotiation:3.4.1")
    implementation("io.ktor:ktor-serialization-kotlinx-json:3.4.1")
    
    // OkHttp
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    implementation("com.squareup.okhttp3:logging-interceptor:5.3.2")
    
    // Device Discovery Dependencies
    implementation("org.jmdns:jmdns:3.6.3")  // mDNS/Bonjour support
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.10.0")
    
    // Bluetooth and WiFi
    implementation("androidx.bluetooth:bluetooth:1.0.0-alpha02")

    // Google Play services - Nearby Connections
    implementation("com.google.android.gms:play-services-nearby:19.3.0")
    
    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    
    // Permissions
    implementation("androidx.activity:activity-ktx:1.13.0")
    implementation("androidx.fragment:fragment-ktx:1.8.9")
    
    implementation("androidx.work:work-runtime-ktx:2.11.1")
    
    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito:mockito-core:5.23.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("io.kotest:kotest-runner-junit5:6.1.6")
    testImplementation("io.kotest:kotest-assertions-core:6.1.6")
    testImplementation("io.kotest:kotest-property:6.1.6")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
