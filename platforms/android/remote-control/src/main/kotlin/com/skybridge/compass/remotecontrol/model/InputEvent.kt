package com.skybridge.compass.remotecontrol.model

import android.os.Parcelable
import kotlinx.parcelize.Parcelize
import kotlinx.serialization.Serializable

/**
 * 输入事件基类
 */
@Serializable
@Parcelize
sealed class InputEvent : Parcelable {
    abstract val timestamp: Long
    abstract val deviceId: String
    abstract val eventId: String
}

/**
 * 触摸事件
 */
@Serializable
@Parcelize
data class TouchEvent(
    override val timestamp: Long,
    override val deviceId: String,
    override val eventId: String,
    val action: TouchAction,
    val x: Float,
    val y: Float,
    val pressure: Float = 1.0f,
    val pointerId: Int = 0,
    val size: Float = 1.0f
) : InputEvent()

/**
 * 触摸动作类型
 */
@Serializable
enum class TouchAction {
    DOWN,       // 按下
    UP,         // 抬起
    MOVE,       // 移动
    CANCEL      // 取消
}

/**
 * 键盘事件
 */
@Serializable
@Parcelize
data class KeyboardEvent(
    override val timestamp: Long,
    override val deviceId: String,
    override val eventId: String,
    val action: KeyAction,
    val keyCode: Int,
    val scanCode: Int = 0,
    val metaState: Int = 0,
    val repeatCount: Int = 0,
    val unicodeChar: Int = 0
) : InputEvent()

/**
 * 按键动作类型
 */
@Serializable
enum class KeyAction {
    DOWN,       // 按下
    UP,         // 抬起
    MULTIPLE    // 多次按键
}

/**
 * 鼠标事件
 */
@Serializable
@Parcelize
data class MouseEvent(
    override val timestamp: Long,
    override val deviceId: String,
    override val eventId: String,
    val action: MouseAction,
    val x: Float,
    val y: Float,
    val button: MouseButton = MouseButton.LEFT,
    val scrollX: Float = 0f,
    val scrollY: Float = 0f
) : InputEvent()

/**
 * 鼠标动作类型
 */
@Serializable
enum class MouseAction {
    PRESS,      // 按下
    RELEASE,    // 释放
    MOVE,       // 移动
    SCROLL,     // 滚动
    ENTER,      // 进入
    EXIT        // 退出
}

/**
 * 鼠标按钮类型
 */
@Serializable
enum class MouseButton {
    LEFT,       // 左键
    RIGHT,      // 右键
    MIDDLE,     // 中键
    BACK,       // 后退键
    FORWARD     // 前进键
}

/**
 * 手势事件
 */
@Serializable
@Parcelize
data class GestureEvent(
    override val timestamp: Long,
    override val deviceId: String,
    override val eventId: String,
    val gestureType: GestureType,
    val startX: Float,
    val startY: Float,
    val endX: Float,
    val endY: Float,
    val scale: Float = 1.0f,
    val rotation: Float = 0f,
    val velocity: Float = 0f,
    val duration: Long = 0L
) : InputEvent()

/**
 * 手势类型
 */
@Serializable
enum class GestureType {
    TAP,            // 点击
    DOUBLE_TAP,     // 双击
    LONG_PRESS,     // 长按
    SWIPE,          // 滑动
    PINCH,          // 捏合
    ROTATE,         // 旋转
    FLING,          // 快速滑动
    DRAG            // 拖拽
}

/**
 * 文本输入事件
 */
@Serializable
@Parcelize
data class TextInputEvent(
    override val timestamp: Long,
    override val deviceId: String,
    override val eventId: String,
    val text: String,
    val selectionStart: Int = 0,
    val selectionEnd: Int = 0,
    val composingStart: Int = -1,
    val composingEnd: Int = -1
) : InputEvent()

/**
 * 系统按键事件
 */
@Serializable
@Parcelize
data class SystemKeyEvent(
    override val timestamp: Long,
    override val deviceId: String,
    override val eventId: String,
    val systemKey: SystemKey,
    val action: KeyAction = KeyAction.DOWN
) : InputEvent()

/**
 * 系统按键类型
 */
@Serializable
enum class SystemKey {
    HOME,           // 主页键
    BACK,           // 返回键
    MENU,           // 菜单键
    RECENT_APPS,    // 最近应用键
    POWER,          // 电源键
    VOLUME_UP,      // 音量加
    VOLUME_DOWN,    // 音量减
    VOLUME_MUTE,    // 静音
    CAMERA,         // 相机键
    SEARCH,         // 搜索键
    NOTIFICATION,   // 通知栏
    SETTINGS,       // 设置
    SCREENSHOT      // 截图
}

/**
 * 输入事件批次
 * 用于批量传输多个输入事件
 */
@Serializable
@Parcelize
data class InputEventBatch(
    val events: List<InputEvent>,
    val batchId: String,
    val timestamp: Long = System.currentTimeMillis(),
    val deviceId: String
) : Parcelable

/**
 * 输入事件响应
 */
@Serializable
@Parcelize
data class InputEventResponse(
    val eventId: String,
    val success: Boolean,
    val errorMessage: String? = null,
    val timestamp: Long = System.currentTimeMillis(),
    val processingTime: Long = 0L
) : Parcelable

/**
 * 输入事件统计
 */
@Serializable
@Parcelize
data class InputEventStats(
    val totalEvents: Long = 0L,
    val touchEvents: Long = 0L,
    val keyboardEvents: Long = 0L,
    val mouseEvents: Long = 0L,
    val gestureEvents: Long = 0L,
    val textInputEvents: Long = 0L,
    val systemKeyEvents: Long = 0L,
    val successfulEvents: Long = 0L,
    val failedEvents: Long = 0L,
    val averageLatency: Double = 0.0,
    val lastEventTime: Long = 0L
) : Parcelable

/**
 * 输入配置
 */
@Serializable
@Parcelize
data class InputConfig(
    val enableTouch: Boolean = true,
    val enableKeyboard: Boolean = true,
    val enableMouse: Boolean = true,
    val enableGesture: Boolean = true,
    val enableTextInput: Boolean = true,
    val enableSystemKeys: Boolean = false,
    val touchSensitivity: Float = 1.0f,
    val mouseSensitivity: Float = 1.0f,
    val gestureThreshold: Float = 10.0f,
    val longPressTimeout: Long = 500L,
    val doubleTapTimeout: Long = 300L,
    val maxBatchSize: Int = 50,
    val batchTimeout: Long = 16L // ~60fps
) : Parcelable

/**
 * 输入事件工具类
 */
object InputEventUtils {
    
    /**
     * 生成事件ID
     */
    fun generateEventId(): String {
        return "${System.currentTimeMillis()}-${(Math.random() * 10000).toInt()}"
    }
    
    /**
     * 创建触摸事件
     */
    fun createTouchEvent(
        deviceId: String,
        action: TouchAction,
        x: Float,
        y: Float,
        pressure: Float = 1.0f
    ): TouchEvent {
        return TouchEvent(
            timestamp = System.currentTimeMillis(),
            deviceId = deviceId,
            eventId = generateEventId(),
            action = action,
            x = x,
            y = y,
            pressure = pressure
        )
    }
    
    /**
     * 创建键盘事件
     */
    fun createKeyboardEvent(
        deviceId: String,
        action: KeyAction,
        keyCode: Int,
        metaState: Int = 0
    ): KeyboardEvent {
        return KeyboardEvent(
            timestamp = System.currentTimeMillis(),
            deviceId = deviceId,
            eventId = generateEventId(),
            action = action,
            keyCode = keyCode,
            metaState = metaState
        )
    }
    
    /**
     * 创建手势事件
     */
    fun createGestureEvent(
        deviceId: String,
        gestureType: GestureType,
        startX: Float,
        startY: Float,
        endX: Float,
        endY: Float
    ): GestureEvent {
        return GestureEvent(
            timestamp = System.currentTimeMillis(),
            deviceId = deviceId,
            eventId = generateEventId(),
            gestureType = gestureType,
            startX = startX,
            startY = startY,
            endX = endX,
            endY = endY
        )
    }
    
    /**
     * 创建文本输入事件
     */
    fun createTextInputEvent(
        deviceId: String,
        text: String
    ): TextInputEvent {
        return TextInputEvent(
            timestamp = System.currentTimeMillis(),
            deviceId = deviceId,
            eventId = generateEventId(),
            text = text
        )
    }
    
    /**
     * 创建系统按键事件
     */
    fun createSystemKeyEvent(
        deviceId: String,
        systemKey: SystemKey,
        action: KeyAction = KeyAction.DOWN
    ): SystemKeyEvent {
        return SystemKeyEvent(
            timestamp = System.currentTimeMillis(),
            deviceId = deviceId,
            eventId = generateEventId(),
            systemKey = systemKey,
            action = action
        )
    }
    
    /**
     * 计算两点之间的距离
     */
    fun calculateDistance(x1: Float, y1: Float, x2: Float, y2: Float): Float {
        val dx = x2 - x1
        val dy = y2 - y1
        return kotlin.math.sqrt(dx * dx + dy * dy)
    }
    
    /**
     * 计算手势速度
     */
    fun calculateVelocity(distance: Float, duration: Long): Float {
        return if (duration > 0) distance / duration * 1000 else 0f
    }
    
    /**
     * 判断是否为有效的触摸坐标
     */
    fun isValidTouchCoordinate(x: Float, y: Float, screenWidth: Int, screenHeight: Int): Boolean {
        return x >= 0 && x <= screenWidth && y >= 0 && y <= screenHeight
    }
}