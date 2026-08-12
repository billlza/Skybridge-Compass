package com.skybridge.compass.android.remote.mac

import kotlinx.serialization.json.Json

/** Connection-generation-owned inputs that require an explicit release before a normal close. */
internal class MacRemotePressedInputState {
    private data class Pointer(val x: Double, val y: Double)

    private val lock = Any()
    private var generation: Long? = null
    private val keyCodes = linkedSetOf<Int>()
    private var leftPointer: Pointer? = null
    private var rightPointer: Pointer? = null

    fun record(input: MacRemoteQueuedInput) {
        val message = RemoteControlWireCodec.decodeMessage(input.encodedMessage())
        synchronized(lock) {
            if (generation != input.generation) {
                generation = input.generation
                keyCodes.clear()
                leftPointer = null
                rightPointer = null
            }
            when (message.type) {
                RemoteMessage.MessageType.KEYBOARD_EVENT -> {
                    val event = RemoteControlWireCodec.decodeKeyboardEvent(message)
                    when (event.type) {
                        KeyboardEventType.KEY_DOWN -> keyCodes += event.keyCode
                        KeyboardEventType.KEY_UP -> keyCodes -= event.keyCode
                    }
                }
                RemoteMessage.MessageType.MOUSE_EVENT -> {
                    val event = RemoteControlWireCodec.decodeMouseEvent(message)
                    val point = Pointer(event.x, event.y)
                    when (event.type) {
                        MouseEventType.LEFT_MOUSE_DOWN -> leftPointer = point
                        MouseEventType.LEFT_MOUSE_UP -> leftPointer = null
                        MouseEventType.RIGHT_MOUSE_DOWN -> rightPointer = point
                        MouseEventType.RIGHT_MOUSE_UP -> rightPointer = null
                        MouseEventType.MOUSE_MOVED -> {
                            if (leftPointer != null) leftPointer = point
                            if (rightPointer != null) rightPointer = point
                        }
                        MouseEventType.SCROLL_UP,
                        MouseEventType.SCROLL_DOWN -> Unit
                    }
                }
                else -> Unit
            }
        }
    }

    fun releaseMessages(
        expectedGeneration: Long,
        json: Json,
        timestamp: Double
    ): List<RemoteMessage> {
        val snapshot = synchronized(lock) {
            if (generation != expectedGeneration) {
                Triple(emptyList(), null, null)
            } else {
                Triple(keyCodes.toList(), leftPointer, rightPointer)
            }
        }
        return buildList {
            snapshot.first.forEach { keyCode ->
                add(
                    RemoteInputMessages.keyboard(
                        json,
                        KeyboardEventType.KEY_UP,
                        MacVirtualKeyCode(keyCode),
                        timestamp
                    )
                )
            }
            snapshot.second?.let { point ->
                add(
                    RemoteInputMessages.mouse(
                        json,
                        MouseEventType.LEFT_MOUSE_UP,
                        point.x,
                        point.y,
                        timestamp
                    )
                )
            }
            snapshot.third?.let { point ->
                add(
                    RemoteInputMessages.mouse(
                        json,
                        MouseEventType.RIGHT_MOUSE_UP,
                        point.x,
                        point.y,
                        timestamp
                    )
                )
            }
        }
    }

    fun clear() {
        synchronized(lock) {
            generation = null
            keyCodes.clear()
            leftPointer = null
            rightPointer = null
        }
    }
}
