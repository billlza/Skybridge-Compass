// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
    id("com.android.application") version "9.1.0" apply false
    id("com.android.library") version "9.1.0" apply false
    id("com.android.test") version "9.1.0" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.3.10" apply false
    id("com.google.dagger.hilt.android") version "2.59.2" apply false
    // Keep KSP aligned with the latest stable Gradle plugin release train.
    id("com.google.devtools.ksp") version "2.3.6" apply false
    // Kotlin 2.0+ Compose Gradle 插件（Android Compose 必需）
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.10" apply false
    id("com.github.ben-manes.versions") version "0.53.0"
}

import com.github.benmanes.gradle.versions.updates.DependencyUpdatesTask

tasks.withType<DependencyUpdatesTask>().configureEach {
    // 仅报告稳定版本（过滤 alpha/beta/rc 等）
    rejectVersionIf {
        val candidate = candidate.version
        val stableKeyword = listOf("RELEASE", "FINAL", "GA").any { key ->
            candidate.uppercase().contains(key)
        }
        val isStable = stableKeyword || Regex("^[0-9,.v-]+(-r)?$").matches(candidate)
        !isStable
    }
    outputFormatter = "plain"
    outputDir = "build/dependencyUpdates"
    reportfileName = "report"
}

tasks.register<Copy>("syncBaselineProfiles") {
    val profiles = fileTree("${project.rootDir}/baselineprofile/build/outputs") {
        include("**/baseline-prof.txt", "**/startup-prof.txt")
    }
    from(profiles)
    into("${project.rootDir}/app/src/main")
    includeEmptyDirs = false
    doFirst {
        if (profiles.files.isEmpty()) {
            logger.warn("No baseline/startup profile files found. Run :baselineprofile:connectedBenchmarkAndroidTest first.")
        }
    }
}
