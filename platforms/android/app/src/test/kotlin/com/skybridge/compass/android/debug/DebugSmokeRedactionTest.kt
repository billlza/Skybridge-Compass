package com.skybridge.compass.android.debug

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DebugSmokeRedactionTest {
    @Test
    fun urlForArtifactRemovesQueryAndFragmentSecrets() {
        val redacted = DebugSmokeRedaction.urlForArtifact(
            "ws://10.0.2.2:18443/ws?token=secret-token#bearer-secret"
        )

        assertTrue(redacted.startsWith("ws://10.0.2.2:18443/ws"))
        assertTrue(redacted.contains("?<redacted>"))
        assertTrue(redacted.contains("#<redacted>"))
        assertFalse(redacted.contains("secret-token"))
        assertFalse(redacted.contains("bearer-secret"))
    }

    @Test
    fun statusLineRedactsEmbeddedUrls() {
        val line = DebugSmokeRedaction.statusLine(
            "boot signaling=wss://example.test/ws?access_token=abc123 pqc=true"
        )

        assertTrue(line.contains("signaling=wss://example.test/ws?<redacted>"))
        assertFalse(line.contains("abc123"))
    }

    @Test
    fun sensitiveValueDoesNotReturnRawIdentifier() {
        val raw = "00008140-000E788401C0801C"
        val redacted = DebugSmokeRedaction.sensitiveValue(raw)

        assertTrue(redacted.contains("present:length=${raw.length}:sha256="))
        assertFalse(redacted.contains(raw))
    }

    @Test
    fun statusLineCollapsesNewlinesAndUnicodeFormatControls() {
        val line = DebugSmokeRedaction.statusLine(
            "failure reason=network\r\nsuccess reason=secure_frame_received\u202Ehidden"
        )

        assertFalse(line.contains('\r'))
        assertFalse(line.contains('\n'))
        assertFalse(line.contains('\u202E'))
        assertTrue(line.contains('\uFFFD'))
    }

    @Test
    fun statusLineHasOneBoundedLength() {
        val line = DebugSmokeRedaction.statusLine("x".repeat(8_192))

        assertTrue(line.length == 2_048)
    }
}
