package com.skybridge.compass.android.remote.mac

import android.view.KeyEvent
import com.skybridge.compass.shared.protocol.CrossPlatformRemoteControlProtocol

/** A local key intent whose integer is explicitly an Android hardware key code. */
internal sealed interface RemoteKeyIntent {
    val androidKeyCode: Int

    /** Named controls exposed by the remote viewer without pretending text is a virtual key. */
    enum class Named(override val androidKeyCode: Int) : RemoteKeyIntent {
        TAB(KeyEvent.KEYCODE_TAB),
        ENTER(KeyEvent.KEYCODE_ENTER),
        ARROW_UP(KeyEvent.KEYCODE_DPAD_UP),
        ARROW_DOWN(KeyEvent.KEYCODE_DPAD_DOWN),
        ARROW_LEFT(KeyEvent.KEYCODE_DPAD_LEFT),
        ARROW_RIGHT(KeyEvent.KEYCODE_DPAD_RIGHT),
        BACKSPACE(KeyEvent.KEYCODE_DEL),
        SPACE(KeyEvent.KEYCODE_SPACE)
    }

    /**
     * Validated physical-key input for a future hardware keyboard surface.
     * Unknown integers and Unicode code points never become remote key events.
     */
    @JvmInline
    value class Hardware private constructor(
        override val androidKeyCode: Int
    ) : RemoteKeyIntent {
        companion object {
            fun fromAndroidKeyCode(androidKeyCode: Int): Hardware? =
                CrossPlatformRemoteControlProtocol.KeyCodeMapping
                    .androidToMacOSOrNull(androidKeyCode)
                    ?.let { Hardware(androidKeyCode) }
        }
    }
}

/** macOS virtual key code accepted by the shipping remote-control wire. */
@JvmInline
internal value class MacVirtualKeyCode internal constructor(val value: Int) {
    init {
        require(value in 0x00..0x7F) { "macOS virtual key code is outside the supported range" }
    }
}

/** The only Android-hardware-key to macOS-virtual-key projection used by remote input. */
internal object RemoteKeyboardInputMapper {
    fun toMacVirtualKeyCode(intent: RemoteKeyIntent): MacVirtualKeyCode =
        MacVirtualKeyCode(
            checkNotNull(
                CrossPlatformRemoteControlProtocol.KeyCodeMapping
                    .androidToMacOSOrNull(intent.androidKeyCode)
            ) {
                "validated Android hardware key has no macOS virtual-key mapping"
            }
        )
}
