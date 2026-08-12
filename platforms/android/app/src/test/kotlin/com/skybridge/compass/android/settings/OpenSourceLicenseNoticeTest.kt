package com.skybridge.compass.android.settings

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class OpenSourceLicenseNoticeTest {
    @Test
    fun packagedWebRtcDependencyHasVisibleCompleteNotices() {
        val root = repositoryRoot()
        val notice = File(
            root,
            "app/src/main/assets/third_party_licenses/webrtc-sdk.txt"
        ).readText()
        val screen = File(
            root,
            "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/AboutSettingsScreen.kt"
        ).readText()

        assertTrue(notice.contains("Copyright (c) 2023 WebRTC SDKs"))
        assertTrue(notice.contains("Copyright (c) 2011, The WebRTC project authors"))
        assertTrue(notice.contains("Redistribution and use in source and binary forms"))
        assertTrue(notice.contains("Neither the name of Google"))
        assertTrue(screen.contains("WebRTC Android SDK"))
        assertTrue(screen.contains("third_party_licenses/webrtc-sdk.txt"))
        assertTrue(screen.contains("Text(webRtcNotice"))
    }

    @Test
    fun staticallyLinkedLiboqsHasVisibleCompleteNotices() {
        val root = repositoryRoot()
        val notice = File(
            root,
            "app/src/main/assets/third_party_licenses/liboqs.txt"
        ).readText()
        val screen = File(
            root,
            "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/AboutSettingsScreen.kt"
        ).readText()

        assertTrue(notice.contains("Copyright (c) 2016-2024 The Open Quantum Safe project authors"))
        assertTrue(notice.contains("Copyright (c) The mlkem-native project authors"))
        assertTrue(notice.contains("Apache License\nVersion 2.0, January 2004"))
        assertTrue(notice.contains("eXtended Keccak Code Package (XKCP)"))
        assertTrue(notice.contains("Copyright (c) 1998-2008, Brian Gladman"))
        assertTrue(screen.contains("liboqs and PQC implementations"))
        assertTrue(screen.contains("third_party_licenses/liboqs.txt"))
        assertTrue(screen.contains("Text(liboqsNotice"))
    }

    private fun repositoryRoot(): File {
        var current = File(".").canonicalFile
        while (!File(current, "settings.gradle.kts").isFile) {
            current = requireNotNull(current.parentFile) {
                "Could not locate repository root from ${File(".").canonicalPath}"
            }
        }
        return current
    }
}
