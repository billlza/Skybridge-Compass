plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.skybridge.compass.shared"
    compileSdk = 36

    defaultConfig {
        minSdk = 33
        
        // NDK configuration for native PQC library
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        
        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                arguments += listOf(
                    "-DANDROID_STL=c++_shared"
                )
            }
        }
    }
    
    // External native build configuration
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        
        release {
            isMinifyEnabled = false
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

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
    
    testOptions {
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
    // Compose BOM
    implementation(platform("androidx.compose:compose-bom:2026.03.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // Kotlin coroutines (for StateFlow in AccountStore)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    implementation("org.bouncycastle:bcprov-jdk18on:1.83")

    // javax.inject annotations used by NetworkOptimizer/ErrorRecoveryManager
    implementation("javax.inject:javax.inject:1")
    
    // OkHttp for WebSocket support
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    
    // Kotlinx Serialization for JSON
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.10.0")
    
    // Testing dependencies
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.junit.jupiter:junit-jupiter-api:6.0.3")
    testRuntimeOnly("org.junit.jupiter:junit-jupiter-engine:6.0.3")
    testImplementation("io.kotest:kotest-runner-junit5:6.1.6")
    testImplementation("io.kotest:kotest-assertions-core:6.1.6")
    testImplementation("io.kotest:kotest-property:6.1.6")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
}
