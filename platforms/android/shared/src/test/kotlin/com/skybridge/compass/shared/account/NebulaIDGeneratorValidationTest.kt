package com.skybridge.compass.shared.account

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NebulaIDGeneratorValidationTest {

    @Test
    fun companionValidationAcceptsCanonicalNebulaId() {
        assertTrue(NebulaIDGenerator.isValidID("NEBULA-2026-ABCDEF123456"))
    }

    @Test
    fun companionValidationRejectsMalformedNebulaIds() {
        assertFalse(NebulaIDGenerator.isValidID("nebula-2026-ABCDEF123456"))
        assertFalse(NebulaIDGenerator.isValidID("NEBULA-year-ABCDEF123456"))
        assertFalse(NebulaIDGenerator.isValidID("NEBULA-26-ABCDEF123456"))
        assertFalse(NebulaIDGenerator.isValidID("NEBULA-2026-ABCDEF12345"))
        assertFalse(NebulaIDGenerator.isValidID("NEBULA-2026-abcdef123456"))
        assertFalse(NebulaIDGenerator.isValidID("NEBULA-2026-ABCDEF12345!"))
        assertFalse(NebulaIDGenerator.isValidID("NEBULA-2026"))
    }
}
