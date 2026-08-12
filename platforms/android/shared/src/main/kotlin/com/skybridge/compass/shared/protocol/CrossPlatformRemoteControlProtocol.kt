package com.skybridge.compass.shared.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 跨平台远程控制协议
 * 
 * 确保 Android 与 iOS/macOS 之间远程控制事件的完全兼容性
 * 
 * 协议格式（与 iOS/macOS RemoteDesktopManager 兼容）:
 * - Magic: "SBRC" (4 bytes)
 * - Version: UInt16 (2 bytes, little-endian)
 * - EventType: UInt8 (1 byte)
 * - Flags: UInt8 (1 byte)
 * - Timestamp: Double (8 bytes, little-endian) - Unix timestamp in seconds
 * - PayloadLength: UInt32 (4 bytes, little-endian)
 * - Payload: [PayloadLength] bytes
 */
object CrossPlatformRemoteControlProtocol {
    
    // 魔数标识
    private val MAGIC = byteArrayOf(0x53, 0x42, 0x52, 0x43) // "SBRC"
    
    // 协议版本
    const val PROTOCOL_VERSION: UShort = 0x0001u
    
    // 事件类型（与 iOS/macOS 保持一致）
    object EventType {
        const val MOUSE_MOVE: UByte = 0x01u        // 鼠标移动
        const val MOUSE_DOWN: UByte = 0x02u        // 鼠标按下
        const val MOUSE_UP: UByte = 0x03u          // 鼠标释放
        const val MOUSE_SCROLL: UByte = 0x04u      // 鼠标滚轮
        const val KEY_DOWN: UByte = 0x10u          // 按键按下
        const val KEY_UP: UByte = 0x11u            // 按键释放
        const val KEY_REPEAT: UByte = 0x12u        // 按键重复
        const val TOUCH_BEGIN: UByte = 0x20u       // 触摸开始
        const val TOUCH_MOVE: UByte = 0x21u        // 触摸移动
        const val TOUCH_END: UByte = 0x22u         // 触摸结束
        const val TOUCH_CANCEL: UByte = 0x23u      // 触摸取消
        const val GESTURE: UByte = 0x30u           // 手势
        const val FRAME: UByte = 0x40u             // 屏幕帧
        const val FRAME_ACK: UByte = 0x41u         // 帧确认
        const val SESSION_START: UByte = 0x80u     // 会话开始
        const val SESSION_END: UByte = 0x81u       // 会话结束
        const val SESSION_ACK: UByte = 0x82u       // 会话确认
        const val SETTINGS: UByte = 0x90u          // 设置更新
    }
    
    // 鼠标按钮（与 macOS NSEvent.EventType 兼容）
    object MouseButton {
        const val LEFT: Int = 0
        const val RIGHT: Int = 1
        const val MIDDLE: Int = 2
        const val BUTTON_4: Int = 3
        const val BUTTON_5: Int = 4
    }
    
    // 修饰键（与 macOS NSEvent.ModifierFlags 兼容）
    object ModifierFlags {
        const val SHIFT: UInt = 0x00020000u
        const val CONTROL: UInt = 0x00040000u
        const val ALT: UInt = 0x00080000u        // Option on macOS
        const val COMMAND: UInt = 0x00100000u    // Meta on Android
        const val CAPS_LOCK: UInt = 0x00010000u
        const val FN: UInt = 0x00800000u
    }
    
    /**
     * 鼠标事件
     * 与 iOS/macOS RemoteDesktopManager.sendMouseEvent 兼容
     */
    data class MouseEvent(
        val sessionId: String,
        val x: Float,           // 归一化坐标 (0-1)
        val y: Float,           // 归一化坐标 (0-1)
        val eventType: UByte,
        val buttonNumber: Int = MouseButton.LEFT,
        val clickCount: Int = 1,
        val modifiers: UInt = 0u,
        val timestamp: Long = System.currentTimeMillis()
    )
    
    /**
     * 键盘事件
     * 与 iOS/macOS RemoteDesktopManager.sendKeyboardEvent 兼容
     */
    data class KeyboardEvent(
        val sessionId: String,
        val keyCode: Int,       // macOS 虚拟键码
        val isPressed: Boolean,
        val characters: String? = null,
        val modifiers: UInt = 0u,
        val isRepeat: Boolean = false,
        val timestamp: Long = System.currentTimeMillis()
    )
    
    /**
     * 滚轮事件
     * 与 iOS/macOS RemoteDesktopManager.sendScrollEvent 兼容
     */
    data class ScrollEvent(
        val sessionId: String,
        val deltaX: Float,
        val deltaY: Float,
        val isPrecise: Boolean = true,  // 触控板精确滚动
        val modifiers: UInt = 0u,
        val timestamp: Long = System.currentTimeMillis()
    )
    
    /**
     * 触摸事件
     * Android 特有，但需要映射到 macOS 手势
     */
    data class TouchEvent(
        val sessionId: String,
        val touchId: Int,
        val x: Float,           // 归一化坐标 (0-1)
        val y: Float,           // 归一化坐标 (0-1)
        val pressure: Float,    // 压力 (0-1)
        val eventType: UByte,
        val timestamp: Long = System.currentTimeMillis()
    )
    
    /**
     * 屏幕帧数据
     * 与 iOS/macOS ScreenCaptureEngine 兼容
     */
    data class ScreenFrame(
        val sessionId: String,
        val frameIndex: Long,
        val width: Int,
        val height: Int,
        val pixelFormat: PixelFormat,
        val data: ByteArray,
        val isKeyframe: Boolean,
        val timestamp: Long = System.currentTimeMillis()
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is ScreenFrame) return false
            return sessionId == other.sessionId && frameIndex == other.frameIndex
        }
        
        override fun hashCode(): Int {
            return 31 * sessionId.hashCode() + frameIndex.hashCode()
        }
    }
    
    /**
     * 像素格式
     * 与 iOS/macOS ScreenCapturePixelFormat 兼容
     */
    enum class PixelFormat(val rawValue: String, val bytesPerPixel: Int) {
        BGRA8888("bgra8888", 4),
        RGBA8888("rgba8888", 4),
        YUV420P("yuv420p", 0),  // 可变
        NV12("nv12", 0);        // 可变
        
        companion object {
            fun fromRawValue(value: String): PixelFormat {
                return values().find { it.rawValue == value } ?: BGRA8888
            }
        }
    }
    
    /**
     * 会话配置
     * 与 iOS/macOS RemoteDesktopSettings 兼容
     */
    data class SessionConfig(
        val sessionId: String,
        val width: Int = 1920,
        val height: Int = 1080,
        val frameRate: Int = 30,
        val pixelFormat: PixelFormat = PixelFormat.BGRA8888,
        val enableCompression: Boolean = true,
        val compressionQuality: Int = 75,
        val enableEncryption: Boolean = true,
        val enableAudio: Boolean = false,
        val colorDepth: Int = 32,
        val deviceName: String = "Android",
        val deviceId: String
    )
    
    /**
     * 序列化鼠标事件
     */
    fun serializeMouseEvent(event: MouseEvent): ByteArray {
        // Payload: sessionId(36) + x(4) + y(4) + button(4) + clickCount(4) + modifiers(4)
        val payload = ByteBuffer.allocate(56)
        payload.order(ByteOrder.LITTLE_ENDIAN)
        
        val sessionIdBytes = event.sessionId.toByteArray(Charsets.UTF_8)
        val paddedSessionId = ByteArray(36)
        System.arraycopy(sessionIdBytes, 0, paddedSessionId, 0, 
            minOf(sessionIdBytes.size, 36))
        payload.put(paddedSessionId)
        
        payload.putFloat(event.x)
        payload.putFloat(event.y)
        payload.putInt(event.buttonNumber)
        payload.putInt(event.clickCount)
        payload.putInt(event.modifiers.toInt())
        
        return buildMessage(
            eventType = event.eventType,
            payload = payload.array(),
            timestamp = event.timestamp
        )
    }
    
    /**
     * 反序列化鼠标事件
     */
    fun deserializeMouseEvent(parsed: ParsedMessage): MouseEvent {
        val payload = ByteBuffer.wrap(parsed.payload)
        payload.order(ByteOrder.LITTLE_ENDIAN)
        
        val sessionIdBytes = ByteArray(36)
        payload.get(sessionIdBytes)
        val sessionId = String(sessionIdBytes, Charsets.UTF_8).trim('\u0000')
        
        val x = payload.float
        val y = payload.float
        val buttonNumber = payload.int
        val clickCount = payload.int
        val modifiers = payload.int.toUInt()
        
        return MouseEvent(
            sessionId = sessionId,
            x = x,
            y = y,
            eventType = parsed.eventType,
            buttonNumber = buttonNumber,
            clickCount = clickCount,
            modifiers = modifiers,
            timestamp = parsed.timestamp
        )
    }
    
    /**
     * 序列化键盘事件
     */
    fun serializeKeyboardEvent(event: KeyboardEvent): ByteArray {
        val characters = event.characters ?: ""
        val charsBytes = characters.toByteArray(Charsets.UTF_8)
        
        // Payload: sessionId(36) + keyCode(4) + isPressed(1) + modifiers(4) + 
        //          isRepeat(1) + charsLength(4) + chars(var)
        val payloadSize = 36 + 4 + 1 + 4 + 1 + 4 + charsBytes.size
        val payload = ByteBuffer.allocate(payloadSize)
        payload.order(ByteOrder.LITTLE_ENDIAN)
        
        val sessionIdBytes = event.sessionId.toByteArray(Charsets.UTF_8)
        val paddedSessionId = ByteArray(36)
        System.arraycopy(sessionIdBytes, 0, paddedSessionId, 0, 
            minOf(sessionIdBytes.size, 36))
        payload.put(paddedSessionId)
        
        payload.putInt(event.keyCode)
        payload.put(if (event.isPressed) 1.toByte() else 0.toByte())
        payload.putInt(event.modifiers.toInt())
        payload.put(if (event.isRepeat) 1.toByte() else 0.toByte())
        payload.putInt(charsBytes.size)
        payload.put(charsBytes)
        
        val eventType = when {
            event.isRepeat -> EventType.KEY_REPEAT
            event.isPressed -> EventType.KEY_DOWN
            else -> EventType.KEY_UP
        }
        
        return buildMessage(
            eventType = eventType,
            payload = payload.array(),
            timestamp = event.timestamp
        )
    }
    
    /**
     * 反序列化键盘事件
     */
    fun deserializeKeyboardEvent(parsed: ParsedMessage): KeyboardEvent {
        val payload = ByteBuffer.wrap(parsed.payload)
        payload.order(ByteOrder.LITTLE_ENDIAN)
        
        val sessionIdBytes = ByteArray(36)
        payload.get(sessionIdBytes)
        val sessionId = String(sessionIdBytes, Charsets.UTF_8).trim('\u0000')
        
        val keyCode = payload.int
        val isPressed = payload.get() == 1.toByte()
        val modifiers = payload.int.toUInt()
        val isRepeat = payload.get() == 1.toByte()
        val charsLength = payload.int
        
        val characters = if (charsLength > 0 && payload.remaining() >= charsLength) {
            val charsBytes = ByteArray(charsLength)
            payload.get(charsBytes)
            String(charsBytes, Charsets.UTF_8)
        } else null
        
        return KeyboardEvent(
            sessionId = sessionId,
            keyCode = keyCode,
            isPressed = isPressed,
            characters = characters,
            modifiers = modifiers,
            isRepeat = isRepeat,
            timestamp = parsed.timestamp
        )
    }
    
    /**
     * 序列化滚轮事件
     */
    fun serializeScrollEvent(event: ScrollEvent): ByteArray {
        // Payload: sessionId(36) + deltaX(4) + deltaY(4) + isPrecise(1) + modifiers(4)
        val payload = ByteBuffer.allocate(49)
        payload.order(ByteOrder.LITTLE_ENDIAN)
        
        val sessionIdBytes = event.sessionId.toByteArray(Charsets.UTF_8)
        val paddedSessionId = ByteArray(36)
        System.arraycopy(sessionIdBytes, 0, paddedSessionId, 0, 
            minOf(sessionIdBytes.size, 36))
        payload.put(paddedSessionId)
        
        payload.putFloat(event.deltaX)
        payload.putFloat(event.deltaY)
        payload.put(if (event.isPrecise) 1.toByte() else 0.toByte())
        payload.putInt(event.modifiers.toInt())
        
        return buildMessage(
            eventType = EventType.MOUSE_SCROLL,
            payload = payload.array(),
            timestamp = event.timestamp
        )
    }
    
    /**
     * 序列化触摸事件
     */
    fun serializeTouchEvent(event: TouchEvent): ByteArray {
        // Payload: sessionId(36) + touchId(4) + x(4) + y(4) + pressure(4)
        val payload = ByteBuffer.allocate(52)
        payload.order(ByteOrder.LITTLE_ENDIAN)
        
        val sessionIdBytes = event.sessionId.toByteArray(Charsets.UTF_8)
        val paddedSessionId = ByteArray(36)
        System.arraycopy(sessionIdBytes, 0, paddedSessionId, 0, 
            minOf(sessionIdBytes.size, 36))
        payload.put(paddedSessionId)
        
        payload.putInt(event.touchId)
        payload.putFloat(event.x)
        payload.putFloat(event.y)
        payload.putFloat(event.pressure)
        
        return buildMessage(
            eventType = event.eventType,
            payload = payload.array(),
            timestamp = event.timestamp
        )
    }
    
    /**
     * 序列化会话配置
     */
    fun serializeSessionConfig(config: SessionConfig): ByteArray {
        val deviceNameBytes = config.deviceName.toByteArray(Charsets.UTF_8)
        val deviceIdBytes = config.deviceId.toByteArray(Charsets.UTF_8)
        
        // 固定部分 + 可变长度字符串
        val payloadSize = 36 + 4 + 4 + 4 + 4 + 1 + 4 + 1 + 1 + 4 + 
            4 + deviceNameBytes.size + 4 + deviceIdBytes.size
        val payload = ByteBuffer.allocate(payloadSize)
        payload.order(ByteOrder.LITTLE_ENDIAN)
        
        val sessionIdBytes = config.sessionId.toByteArray(Charsets.UTF_8)
        val paddedSessionId = ByteArray(36)
        System.arraycopy(sessionIdBytes, 0, paddedSessionId, 0, 
            minOf(sessionIdBytes.size, 36))
        payload.put(paddedSessionId)
        
        payload.putInt(config.width)
        payload.putInt(config.height)
        payload.putInt(config.frameRate)
        payload.putInt(config.pixelFormat.ordinal)
        payload.put(if (config.enableCompression) 1.toByte() else 0.toByte())
        payload.putInt(config.compressionQuality)
        payload.put(if (config.enableEncryption) 1.toByte() else 0.toByte())
        payload.put(if (config.enableAudio) 1.toByte() else 0.toByte())
        payload.putInt(config.colorDepth)
        
        payload.putInt(deviceNameBytes.size)
        payload.put(deviceNameBytes)
        payload.putInt(deviceIdBytes.size)
        payload.put(deviceIdBytes)
        
        return buildMessage(
            eventType = EventType.SESSION_START,
            payload = payload.array(),
            timestamp = System.currentTimeMillis()
        )
    }
    
    /**
     * 构建协议消息
     */
    fun buildMessage(
        eventType: UByte,
        payload: ByteArray,
        timestamp: Long = System.currentTimeMillis(),
        flags: UByte = 0u
    ): ByteArray {
        val buffer = ByteBuffer.allocate(20 + payload.size)
        buffer.order(ByteOrder.LITTLE_ENDIAN)
        
        // Magic (4 bytes)
        buffer.put(MAGIC)
        
        // Version (2 bytes)
        buffer.putShort(PROTOCOL_VERSION.toShort())
        
        // EventType (1 byte)
        buffer.put(eventType.toByte())
        
        // Flags (1 byte)
        buffer.put(flags.toByte())
        
        // Timestamp (8 bytes) - Unix timestamp in seconds (Double)
        buffer.putDouble(timestamp / 1000.0)
        
        // PayloadLength (4 bytes)
        buffer.putInt(payload.size)
        
        // Payload
        buffer.put(payload)
        
        return buffer.array()
    }
    
    /**
     * 解析协议消息
     */
    fun parseMessage(data: ByteArray): ParsedMessage {
        require(data.size >= 20) { "Message too short: ${data.size}" }
        
        val buffer = ByteBuffer.wrap(data)
        buffer.order(ByteOrder.LITTLE_ENDIAN)
        
        // Verify magic
        val magic = ByteArray(4)
        buffer.get(magic)
        require(magic.contentEquals(MAGIC)) { "Invalid magic: ${magic.contentToString()}" }
        
        val version = buffer.short.toUShort()
        val eventType = buffer.get().toUByte()
        val flags = buffer.get().toUByte()
        val timestampSeconds = buffer.double
        val timestamp = (timestampSeconds * 1000).toLong()
        val payloadLength = buffer.int
        
        require(data.size >= 20 + payloadLength) { 
            "Incomplete message: expected ${20 + payloadLength}, got ${data.size}" 
        }
        
        val payload = ByteArray(payloadLength)
        buffer.get(payload)
        
        return ParsedMessage(version, eventType, flags, timestamp, payload)
    }
    
    data class ParsedMessage(
        val version: UShort,
        val eventType: UByte,
        val flags: UByte,
        val timestamp: Long,
        val payload: ByteArray
    )
    
    /**
     * Android KeyCode 到 macOS 虚拟键码的映射
     */
    object KeyCodeMapping {
        // Android KeyEvent.KEYCODE_* -> macOS virtual key code
        private val androidToMacOS = mapOf(
            // 字母键
            29 to 0x00,  // A
            30 to 0x0B,  // B
            31 to 0x08,  // C
            32 to 0x02,  // D
            33 to 0x0E,  // E
            34 to 0x03,  // F
            35 to 0x05,  // G
            36 to 0x04,  // H
            37 to 0x22,  // I
            38 to 0x26,  // J
            39 to 0x28,  // K
            40 to 0x25,  // L
            41 to 0x2E,  // M
            42 to 0x2D,  // N
            43 to 0x1F,  // O
            44 to 0x23,  // P
            45 to 0x0C,  // Q
            46 to 0x0F,  // R
            47 to 0x01,  // S
            48 to 0x11,  // T
            49 to 0x20,  // U
            50 to 0x09,  // V
            51 to 0x0D,  // W
            52 to 0x07,  // X
            53 to 0x10,  // Y
            54 to 0x06,  // Z
            
            // 数字键
            7 to 0x1D,   // 0
            8 to 0x12,   // 1
            9 to 0x13,   // 2
            10 to 0x14,  // 3
            11 to 0x15,  // 4
            12 to 0x17,  // 5
            13 to 0x16,  // 6
            14 to 0x1A,  // 7
            15 to 0x1C,  // 8
            16 to 0x19,  // 9
            
            // 特殊键
            62 to 0x31,  // SPACE
            66 to 0x24,  // ENTER
            67 to 0x33,  // DELETE (Backspace)
            112 to 0x75, // FORWARD_DELETE
            61 to 0x30,  // TAB
            111 to 0x35, // ESCAPE
            
            // 方向键
            19 to 0x7E,  // DPAD_UP
            20 to 0x7D,  // DPAD_DOWN
            21 to 0x7B,  // DPAD_LEFT
            22 to 0x7C,  // DPAD_RIGHT
            
            // 功能键
            131 to 0x7A, // F1
            132 to 0x78, // F2
            133 to 0x63, // F3
            134 to 0x76, // F4
            135 to 0x60, // F5
            136 to 0x61, // F6
            137 to 0x62, // F7
            138 to 0x64, // F8
            139 to 0x65, // F9
            140 to 0x6D, // F10
            141 to 0x67, // F11
            142 to 0x6F, // F12
            
            // 修饰键
            59 to 0x38,  // SHIFT_LEFT
            60 to 0x3C,  // SHIFT_RIGHT
            113 to 0x3B, // CTRL_LEFT
            114 to 0x3E, // CTRL_RIGHT
            57 to 0x3A,  // ALT_LEFT (Option)
            58 to 0x3D,  // ALT_RIGHT
            117 to 0x37, // META_LEFT (Command)
            118 to 0x36, // META_RIGHT (Right Command)
            
            // 符号键
            55 to 0x2B,  // COMMA
            56 to 0x2F,  // PERIOD
            76 to 0x2C,  // SLASH
            74 to 0x29,  // SEMICOLON
            75 to 0x27,  // APOSTROPHE
            71 to 0x21,  // LEFT_BRACKET
            72 to 0x1E,  // RIGHT_BRACKET
            73 to 0x2A,  // BACKSLASH
            69 to 0x1B,  // MINUS
            70 to 0x18,  // EQUALS
            68 to 0x32   // GRAVE
        )
        
        private val macOSToAndroid = androidToMacOS.entries.associate { (k, v) -> v to k }

        /**
         * Strict Android-key lookup for outbound remote input.
         *
         * The wire carries a macOS virtual key code, not a Unicode code point and not an arbitrary
         * Android integer. Callers at an input boundary must use this nullable lookup and reject an
         * unmapped key instead of forwarding the source value as a different Mac key.
         */
        fun androidToMacOSOrNull(androidKeyCode: Int): Int? = androidToMacOS[androidKeyCode]

        fun macOSToAndroidOrNull(macOSKeyCode: Int): Int? = macOSToAndroid[macOSKeyCode]
    }
    
    /**
     * Android 修饰键到 macOS ModifierFlags 的转换
     */
    fun androidModifiersToMacOS(androidMetaState: Int): UInt {
        var macModifiers = 0u
        
        // 检查 Android meta state 标志
        if (androidMetaState and 0x00000001 != 0 || // META_SHIFT_LEFT_ON
            androidMetaState and 0x00000002 != 0) { // META_SHIFT_RIGHT_ON
            macModifiers = macModifiers or ModifierFlags.SHIFT
        }
        
        if (androidMetaState and 0x00001000 != 0 || // META_CTRL_LEFT_ON
            androidMetaState and 0x00002000 != 0) { // META_CTRL_RIGHT_ON
            macModifiers = macModifiers or ModifierFlags.CONTROL
        }
        
        if (androidMetaState and 0x00000010 != 0 || // META_ALT_LEFT_ON
            androidMetaState and 0x00000020 != 0) { // META_ALT_RIGHT_ON
            macModifiers = macModifiers or ModifierFlags.ALT
        }
        
        if (androidMetaState and 0x00010000 != 0 || // META_META_LEFT_ON
            androidMetaState and 0x00020000 != 0) { // META_META_RIGHT_ON
            macModifiers = macModifiers or ModifierFlags.COMMAND
        }
        
        if (androidMetaState and 0x00100000 != 0) { // META_CAPS_LOCK_ON
            macModifiers = macModifiers or ModifierFlags.CAPS_LOCK
        }
        
        if (androidMetaState and 0x00200000 != 0) { // META_FUNCTION_ON
            macModifiers = macModifiers or ModifierFlags.FN
        }
        
        return macModifiers
    }
    
    /**
     * macOS ModifierFlags 到 Android meta state 的转换
     */
    fun macOSModifiersToAndroid(macModifiers: UInt): Int {
        var androidMetaState = 0
        
        if (macModifiers and ModifierFlags.SHIFT != 0u) {
            androidMetaState = androidMetaState or 0x00000001 // META_SHIFT_LEFT_ON
        }
        
        if (macModifiers and ModifierFlags.CONTROL != 0u) {
            androidMetaState = androidMetaState or 0x00001000 // META_CTRL_LEFT_ON
        }
        
        if (macModifiers and ModifierFlags.ALT != 0u) {
            androidMetaState = androidMetaState or 0x00000010 // META_ALT_LEFT_ON
        }
        
        if (macModifiers and ModifierFlags.COMMAND != 0u) {
            androidMetaState = androidMetaState or 0x00010000 // META_META_LEFT_ON
        }
        
        if (macModifiers and ModifierFlags.CAPS_LOCK != 0u) {
            androidMetaState = androidMetaState or 0x00100000 // META_CAPS_LOCK_ON
        }
        
        if (macModifiers and ModifierFlags.FN != 0u) {
            androidMetaState = androidMetaState or 0x00200000 // META_FUNCTION_ON
        }
        
        return androidMetaState
    }
}
