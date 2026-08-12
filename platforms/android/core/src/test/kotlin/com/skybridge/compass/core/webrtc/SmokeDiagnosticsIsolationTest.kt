package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class SmokeDiagnosticsIsolationTest {

    @Test
    fun productSourcesDoNotReadSmokeSystemProperties() {
        val root = repositoryRoot()
        val productSourceRoots = listOf(
            "app/src/main",
            "core/src/main",
            "shared/src/main",
            "device-discovery/src/main",
            "file-transfer/src/main",
            "remote-control/src/main"
        )
        val forbidden = Regex("""System\.(getProperty|setProperty|clearProperty)\("skybridge\.smoke""")
        val violations = productSourceRoots
            .map { File(root, it) }
            .filter { it.isDirectory }
            .flatMap { sourceRoot ->
                sourceRoot.walkTopDown()
                    .filter { it.isFile && it.extension == "kt" }
                    .flatMap { file ->
                        file.readLines().mapIndexedNotNull { index, line ->
                            if (forbidden.containsMatchIn(line)) {
                                "${file.relativeTo(root).path}:${index + 1}:$line"
                            } else {
                                null
                            }
                        }
                    }
                    .toList()
            }

        assertTrue(
            "Smoke diagnostics must be explicit typed config outside src/main, not product System properties:\n" +
                violations.joinToString("\n"),
            violations.isEmpty()
        )
    }

    @Test
    fun coreDoesNotKnowAppSupabaseSessionStorageFormat() {
        val root = repositoryRoot()
        val coreSourceRoot = File(root, "core/src/main")
        val forbidden = listOf(
            "sb_supabase_session_encrypted",
            "SupabaseSessionStore",
            "CurrentPathAuthSessionStore"
        )
        val violations = coreSourceRoot.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file ->
                file.readLines().mapIndexedNotNull { index, line ->
                    forbidden.firstOrNull { line.contains(it) }?.let {
                        "${file.relativeTo(root).path}:${index + 1}:$line"
                    }
                }
            }
            .toList()

        assertTrue(
            "core must receive WebRTC auth context through app injection, not app/Supabase storage details:\n" +
                violations.joinToString("\n"),
            violations.isEmpty()
        )
    }

    private fun repositoryRoot(): File {
        var current = File(".").canonicalFile
        while (!File(current, "settings.gradle.kts").isFile) {
            current = requireNotNull(current.parentFile) {
                "Could not locate repository root from ${File(".").canonicalPath}"
            }
        }
        require(File(current, "settings.gradle.kts").isFile) {
            "Could not locate repository root from ${File(".").canonicalPath}"
        }
        return current
    }
}
