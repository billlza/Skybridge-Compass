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
    namespace = "com.skybridge.compass.filetransfer"
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
    // Core dependencies
    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.10.0")
    implementation("androidx.activity:activity-compose:1.13.0")
    
    // Compose
    implementation(platform("androidx.compose:compose-bom:2026.03.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.hilt:hilt-navigation-compose:1.3.0")
    
    // Hilt
    implementation("com.google.dagger:hilt-android:2.59.2")
    ksp("com.google.dagger:hilt-compiler:2.59.2")
    
    // Ktor Client Dependencies
    implementation("io.ktor:ktor-client-core:3.4.1")
    implementation("io.ktor:ktor-client-android:3.4.1")
    implementation("io.ktor:ktor-client-websockets:3.4.1")
    implementation("io.ktor:ktor-client-content-negotiation:3.4.1")
    implementation("io.ktor:ktor-serialization-kotlinx-json:3.4.1")
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    
    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    
    // Serialization
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.10.0")
    
    // Work Manager - latest version
    implementation("androidx.work:work-runtime-ktx:2.11.1")
    
    // File handling
    implementation("androidx.documentfile:documentfile:1.1.0")
    
    // Local modules
    implementation(project(":core"))
    implementation(project(":shared"))
    
    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("io.kotest:kotest-runner-junit5:6.1.6")
    testImplementation("io.kotest:kotest-assertions-core:6.1.6")
    testImplementation("io.kotest:kotest-property:6.1.6")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.03.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
