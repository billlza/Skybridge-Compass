import java.io.File

val codexJavaFromEnv = System.getenv("CODEX_JAVA_HOME")?.takeIf { it.isNotBlank() }?.let(::File)
val codexDefaultJavaHome = File("/root/.local/share/mise/installs/java/21.0.2")
val codexJavaHome = listOfNotNull(codexJavaFromEnv, codexDefaultJavaHome.takeIf(File::isDirectory))
    .firstOrNull(File::isDirectory)
if (System.getProperty("org.gradle.java.home").isNullOrBlank() && codexJavaHome != null) {
    System.setProperty("org.gradle.java.home", codexJavaHome.absolutePath)
}

val offlineRepository = rootDir.resolve("third_party/m2repository")

pluginManagement {
    repositories {
        if (offlineRepository.isDirectory) {
            maven {
                url = offlineRepository.toURI()
            }
        }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        if (offlineRepository.isDirectory) {
            maven {
                url = offlineRepository.toURI()
            }
        }
        google()
        mavenCentral()
    }
}

rootProject.name = "YunQiaoSiNan"
include(":app")
