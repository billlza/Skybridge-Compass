package com.skybridge.compass.android.remote.mac

import kotlinx.serialization.json.Json

/**
 * Pure builders that turn a local pointer / keyboard / scroll interaction into a wire-compatible
 * [RemoteMessage] (R6.3). Every builder REUSES the existing message types and fields — no new wire
 * fields are introduced (G4):
 *  - pointer  → [RemoteMessage.MessageType.MOUSE_EVENT] carrying a [RemoteMouseEvent]
 *  - keyboard → [RemoteMessage.MessageType.KEYBOARD_EVENT] carrying a [RemoteKeyboardEvent]
 *  - scroll   → [RemoteMessage.MessageType.MOUSE_EVENT] carrying a [RemoteMouseEvent] whose
 *               [MouseEventType] is [MouseEventType.SCROLL_UP] / [MouseEventType.SCROLL_DOWN]
 *
 * Scroll is expressed purely as a mouse event with a scroll [MouseEventType], exactly as the macOS
 * host expects, so the wire protocol is unchanged.
 */
object RemoteInputMessages {

    /** Scroll direction, mapped onto the existing scroll [MouseEventType] values. */
    enum class ScrollDirection(val mouseEventType: MouseEventType) {
        UP(MouseEventType.SCROLL_UP),
        DOWN(MouseEventType.SCROLL_DOWN)
    }

    fun mouse(
        json: Json,
        type: MouseEventType,
        x: Double,
        y: Double,
        timestamp: Double
    ): RemoteMessage {
        val evt = RemoteMouseEvent(type = type, x = x, y = y, timestamp = timestamp)
        val payload = json.encodeToString(RemoteMouseEvent.serializer(), evt).encodeToByteArray()
        return RemoteMessage(type = RemoteMessage.MessageType.MOUSE_EVENT, payload = payload)
    }

    internal fun keyboard(
        json: Json,
        type: KeyboardEventType,
        keyCode: MacVirtualKeyCode,
        timestamp: Double
    ): RemoteMessage {
        val evt = RemoteKeyboardEvent(type = type, keyCode = keyCode.value, timestamp = timestamp)
        val payload = json.encodeToString(RemoteKeyboardEvent.serializer(), evt).encodeToByteArray()
        return RemoteMessage(type = RemoteMessage.MessageType.KEYBOARD_EVENT, payload = payload)
    }

    /** One logical key press; callers must preserve this Down/Up adjacency when committing it. */
    internal fun keyStroke(
        json: Json,
        keyCode: MacVirtualKeyCode,
        timestamp: Double
    ): List<RemoteMessage> = listOf(
        keyboard(json, KeyboardEventType.KEY_DOWN, keyCode, timestamp),
        keyboard(json, KeyboardEventType.KEY_UP, keyCode, timestamp)
    )

    fun scroll(
        json: Json,
        direction: ScrollDirection,
        x: Double,
        y: Double,
        timestamp: Double
    ): RemoteMessage = mouse(json, direction.mouseEventType, x, y, timestamp)
}
