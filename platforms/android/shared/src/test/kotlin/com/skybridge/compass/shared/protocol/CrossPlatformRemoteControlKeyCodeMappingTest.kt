package com.skybridge.compass.shared.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class CrossPlatformRemoteControlKeyCodeMappingTest {
    @Test
    fun strictAndroidLookupReturnsMacVirtualKeysForSupportedHardwareKeys() {
        val expected = mapOf(
            29 to 0x00, // A
            54 to 0x06, // Z
            7 to 0x1D, // 0
            16 to 0x19, // 9
            62 to 0x31, // Space
            67 to 0x33, // Backspace
            61 to 0x30, // Tab
            66 to 0x24, // Enter
            19 to 0x7E, // Up
            20 to 0x7D, // Down
            21 to 0x7B, // Left
            22 to 0x7C, // Right
            59 to 0x38, // Left Shift
            117 to 0x37, // Left Command
            118 to 0x36 // Right Command
        )

        expected.forEach { (androidKeyCode, macVirtualKeyCode) ->
            assertEquals(
                macVirtualKeyCode,
                CrossPlatformRemoteControlProtocol.KeyCodeMapping
                    .androidToMacOSOrNull(androidKeyCode)
            )
        }
    }

    @Test
    fun strictReverseLookupKeepsLeftAndRightCommandDistinct() {
        assertEquals(
            117,
            CrossPlatformRemoteControlProtocol.KeyCodeMapping.macOSToAndroidOrNull(0x37)
        )
        assertEquals(
            118,
            CrossPlatformRemoteControlProtocol.KeyCodeMapping.macOSToAndroidOrNull(0x36)
        )
    }

    @Test
    fun strictAndroidLookupRejectsUnicodeAndUnknownIntegers() {
        assertNull(
            CrossPlatformRemoteControlProtocol.KeyCodeMapping
                .androidToMacOSOrNull('a'.code)
        )
        assertNull(
            CrossPlatformRemoteControlProtocol.KeyCodeMapping
                .androidToMacOSOrNull(Int.MAX_VALUE)
        )
    }
}
