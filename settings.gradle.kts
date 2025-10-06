import java.io.File

val codexJavaFromEnv = System.getenv("CODEX_JAVA_HOME")?.takeIf { it.isNotBlank() }?.let(::File)
val codexDefaultJavaHome = File("/root/.local/share/mise/installs/java/21.0.2")
val codexJavaHome = listOfNotNull(codexJavaFromEnv, codexDefaultJavaHome.takeIf(File::isDirectory))
    .firstOrNull(File::isDirectory)
if (System.getProperty("org.gradle.java.home").isNullOrBlank() && codexJavaHome != null) {
    System.setProperty("org.gradle.java.home", codexJavaHome.absolutePath)
}

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        val offlineRepo = File(rootDir, "third_party/m2repository")
        if (offlineRepo.isDirectory) {
            maven { url = uri(offlineRepo) }
        }
        google()
        mavenCentral()
    }
}

rootProject.name = "YunQiaoSiNan"
include(":app")

