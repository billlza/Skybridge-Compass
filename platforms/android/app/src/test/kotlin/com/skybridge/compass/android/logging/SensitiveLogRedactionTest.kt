package com.skybridge.compass.android.logging

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SensitiveLogRedactionTest {
    @Test
    fun identifierKeepsLengthAndStableHashWithoutRawValue() {
        val raw = "98D7C5D0-10BE-4C9D-A5B9-91467705F927"

        val redacted = SensitiveLogRedaction.identifier(raw)

        assertTrue(redacted.contains("present:length=${raw.length}:sha256="))
        assertFalse(redacted.contains(raw))
    }

    @Test
    fun identifierReportsMissingForBlankValue() {
        assertTrue(SensitiveLogRedaction.identifier(" ").contains("missing"))
    }
}
