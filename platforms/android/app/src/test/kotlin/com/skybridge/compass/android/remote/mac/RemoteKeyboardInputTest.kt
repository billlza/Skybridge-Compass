package com.skybridge.compass.android.remote.mac

import android.view.KeyEvent
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class RemoteKeyboardInputTest {
    @Test
    fun namedControlsMapToExactMacVirtualKeyCodes() {
        val expected = mapOf(
            RemoteKeyIntent.Named.TAB to 0x30,
            RemoteKeyIntent.Named.ENTER to 0x24,
            RemoteKeyIntent.Named.ARROW_UP to 0x7E,
            RemoteKeyIntent.Named.ARROW_DOWN to 0x7D,
            RemoteKeyIntent.Named.ARROW_LEFT to 0x7B,
            RemoteKeyIntent.Named.ARROW_RIGHT to 0x7C,
            RemoteKeyIntent.Named.BACKSPACE to 0x33,
            RemoteKeyIntent.Named.SPACE to 0x31
        )

        expected.forEach { (intent, macVirtualKeyCode) ->
            assertEquals(
                macVirtualKeyCode,
                RemoteKeyboardInputMapper.toMacVirtualKeyCode(intent).value
            )
        }
    }

    @Test
    fun hardwareIntentAcceptsMappedAndroidKeysAndRejectsUnicodeOrUnknownIntegers() {
        val hardwareA = RemoteKeyIntent.Hardware.fromAndroidKeyCode(KeyEvent.KEYCODE_A)
        val leftCommand = RemoteKeyIntent.Hardware.fromAndroidKeyCode(KeyEvent.KEYCODE_META_LEFT)
        val rightCommand = RemoteKeyIntent.Hardware.fromAndroidKeyCode(KeyEvent.KEYCODE_META_RIGHT)

        assertEquals(
            0x00,
            RemoteKeyboardInputMapper.toMacVirtualKeyCode(requireNotNull(hardwareA)).value
        )
        assertEquals(
            0x37,
            RemoteKeyboardInputMapper.toMacVirtualKeyCode(requireNotNull(leftCommand)).value
        )
        assertEquals(
            0x36,
            RemoteKeyboardInputMapper.toMacVirtualKeyCode(requireNotNull(rightCommand)).value
        )
        assertNull(RemoteKeyIntent.Hardware.fromAndroidKeyCode('a'.code))
        assertNull(RemoteKeyIntent.Hardware.fromAndroidKeyCode(Int.MAX_VALUE))
    }

    @Test
    fun keyboardBuilderWritesMacVirtualKeyRatherThanAndroidOrUnicodeCodePoint() {
        val json = Json { explicitNulls = false }
        val message = RemoteInputMessages.keyboard(
            json = json,
            type = KeyboardEventType.KEY_DOWN,
            keyCode = RemoteKeyboardInputMapper.toMacVirtualKeyCode(RemoteKeyIntent.Named.ENTER),
            timestamp = 1.0
        )

        val event = RemoteControlWireCodec.decodeKeyboardEvent(message)
        assertEquals(KeyboardEventType.KEY_DOWN, event.type)
        assertEquals(0x24, event.keyCode)
    }

    @Test
    fun macVirtualKeyValueRejectsIntegersOutsideTheRepresentableKeyRange() {
        assertThrows(IllegalArgumentException::class.java) { MacVirtualKeyCode(-1) }
        assertThrows(IllegalArgumentException::class.java) { MacVirtualKeyCode(0x80) }
    }
}
