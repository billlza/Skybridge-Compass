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
        google()
        mavenCentral()
        maven("https://jitpack.io")
    }
}

rootProject.name = "SkyBridge Compass Android"
include(":app")
include(":core")
include(":device-discovery")
include(":screen-mirroring")
include(":remote-control")
include(":file-transfer")
include(":shared")
include(":baselineprofile")