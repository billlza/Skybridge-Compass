plugins {
    id("com.android.library")
    id("com.google.devtools.ksp")
    id("dagger.hilt.android.plugin")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("kotlin-parcelize")
    // Kotlin 2.0+ Compose Gradle 插件（Android Compose 必需）
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.skybridge.compass.core"
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
        buildConfig = true
    }

    lint {
        targetSdk = 36
    }

    testOptions {
        targetSdk = 36
    }

    // 使用 Kotlin Compose 插件后不再需要 legacy 的 composeOptions
    // composeOptions {
    //     kotlinCompilerExtensionVersion = "1.5.13"
    // }
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        freeCompilerArgs.add("-Xannotation-default-target=param-property")
    }
}

dependencies {
    implementation(project(":shared"))
    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.10.0")
    implementation("androidx.security:security-crypto:1.1.0")

    implementation(platform("androidx.compose:compose-bom:2026.03.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")

    // Hilt (core applies Hilt Gradle plugin)
    implementation("com.google.dagger:hilt-android:2.59.2")
    ksp("com.google.dagger:hilt-compiler:2.59.2")

    // Coroutines (Flow API used in DAO/Repository)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")

    // Room (runtime + Kotlin extensions)
    implementation("androidx.room:room-runtime:2.8.4")
    implementation("androidx.room:room-ktx:2.8.4")
    // Room code generation via KSP
    ksp("androidx.room:room-compiler:2.8.4")

    // Serialization
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.10.0")

    // Ktor (used by NetworkManager)
    implementation("io.ktor:ktor-client-core:3.4.1")
    implementation("io.ktor:ktor-client-android:3.4.1")
    implementation("io.ktor:ktor-client-okhttp:3.4.1")
    implementation("io.ktor:ktor-client-content-negotiation:3.4.1")
    implementation("io.ktor:ktor-serialization-kotlinx-json:3.4.1")
    implementation("io.ktor:ktor-client-websockets:3.4.1")
    implementation("androidx.datastore:datastore-preferences:1.2.1")

    // WebRTC (DataChannel / ICE) for cross-network file transfer interop with macOS/iOS Pro release
    // NOTE: Version pinned for reproducible builds.
    implementation("com.infobip:google-webrtc:1.0.45036")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
