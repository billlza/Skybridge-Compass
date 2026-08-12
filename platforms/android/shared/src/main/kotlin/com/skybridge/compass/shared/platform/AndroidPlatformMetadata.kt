package com.skybridge.compass.shared.platform

object AndroidPlatformMetadata {
    fun versionString(release: String?, sdkInt: Int): String {
        val trimmedRelease = release?.trim()?.takeIf { it.isNotEmpty() } ?: "unknown"
        return "Android $trimmedRelease (API $sdkInt)"
    }
}
