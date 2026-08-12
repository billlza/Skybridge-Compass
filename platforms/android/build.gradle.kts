// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.android.test) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.hilt.android) apply false
    // Keep KSP aligned with the latest stable Gradle plugin release train.
    alias(libs.plugins.ksp) apply false
    // Kotlin 2.0+ Compose Gradle 插件（Android Compose 必需）
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.ben.manes.versions)
}

import com.github.benmanes.gradle.versions.updates.DependencyUpdatesTask
import com.android.build.api.variant.ApplicationAndroidComponentsExtension
import com.android.build.api.variant.HasUnitTest
import com.android.build.api.variant.LibraryAndroidComponentsExtension
import com.android.build.api.variant.UnitTest
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.tasks.Classpath
import org.gradle.api.tasks.testing.Test
import org.gradle.process.CommandLineArgumentProvider

abstract class ByteBuddyAgentArgumentProvider : CommandLineArgumentProvider {
    @get:Classpath
    abstract val agentJar: RegularFileProperty

    override fun asArguments(): Iterable<String> =
        listOf(
            "-Xshare:off",
            "-javaagent:${agentJar.get().asFile.absolutePath}",
        )
}

fun Project.configureMockKByteBuddyAgent(unitTest: UnitTest) {
    val agentArtifacts = unitTest.runtimeConfiguration.incoming.artifactView {
        componentFilter { componentId ->
            componentId is ModuleComponentIdentifier &&
                componentId.group == "net.bytebuddy" &&
                componentId.module == "byte-buddy-agent"
        }
    }.files

    unitTest.configureTestTask { testTask: Test ->
        val testTaskPath = testTask.path
        val agentJar = agentArtifacts.elements.map { entries ->
            val matches = entries.map { it.asFile }
            check(matches.size == 1) {
                "Expected exactly one Byte Buddy agent on $testTaskPath runtime classpath; " +
                    "found ${matches.map { it.name }}"
            }
            matches.single()
        }
        testTask.jvmArgumentProviders.add(
            objects.newInstance<ByteBuddyAgentArgumentProvider>().apply {
                this.agentJar.fileProvider(agentJar)
            }
        )
    }
}

// MockK already contributes the matching Byte Buddy agent. Preload that exact artifact for every
// Android JVM unit-test variant that uses MockK, instead of relying on deprecated self-attachment.
val mockKUnitTestProjects = setOf(":app", ":device-discovery", ":remote-control")
subprojects {
    if (path !in mockKUnitTestProjects) return@subprojects

    pluginManager.withPlugin("com.android.application") {
        extensions.configure<ApplicationAndroidComponentsExtension> {
            onVariants(selector().all()) { variant ->
                val unitTest = (variant as HasUnitTest).unitTest ?: return@onVariants
                this@subprojects.configureMockKByteBuddyAgent(unitTest)
            }
        }
    }
    pluginManager.withPlugin("com.android.library") {
        extensions.configure<LibraryAndroidComponentsExtension> {
            onVariants(selector().all()) { variant ->
                val unitTest = (variant as HasUnitTest).unitTest ?: return@onVariants
                this@subprojects.configureMockKByteBuddyAgent(unitTest)
            }
        }
    }
}

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
