package com.skybridge.compass.remotecontrol.execution

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Path
import android.media.AudioManager
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.remotecontrol.admission.Admission
import com.skybridge.compass.remotecontrol.admission.RemoteInputAdmissionGate
import com.skybridge.compass.remotecontrol.model.*
import com.skybridge.compass.remotecontrol.secure.RemoteControlSecureEnvelope.PacketType
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 输入执行管理器
 * 负责在目标设备上执行接收到的输入事件
 */
@Singleton
class InputExecutionManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    
    // 执行状态
    private val _isExecutionActive = MutableStateFlow(false)
    val isExecutionActive: StateFlow<Boolean> = _isExecutionActive.asStateFlow()
    
    // 执行统计
    private val _executionStats = MutableStateFlow(InputEventStats())
    val executionStats: StateFlow<InputEventStats> = _executionStats.asStateFlow()
    
    // 无障碍服务引用
    private var accessibilityService: AccessibilityService? = null
    
    // 执行配置
    private val _executionConfig = MutableStateFlow(InputConfig())
    val executionConfig: StateFlow<InputConfig> = _executionConfig.asStateFlow()
    
    // 执行结果流
    private val _executionResults = MutableSharedFlow<InputEventResponse>()
    val executionResults: SharedFlow<InputEventResponse> = _executionResults.asSharedFlow()

    /**
     * 远程输入准入门（R6.7/R6.8）：复用信封计数器做严格单调 + 256 事件接受窗口，
     * 仅放行来自已授权对端的事件，拒绝时记审计事件。
     */
    val admissionGate = RemoteInputAdmissionGate()

    /**
     * 本地停止硬门（R6.7）：触发后同步置位，后续事件立即丢弃，无需等待协程调度。
     */
    private val injectionHardStopped = AtomicBoolean(false)

    /** 在途注入任务，本地停止时一并取消，使全部注入在 1 秒内停止。 */
    private val inFlightInjections: MutableSet<Job> =
        Collections.newSetFromMap(ConcurrentHashMap<Job, Boolean>())

    /** 本地停止入口是否已触发（可观测，供测试与 UI 断言）。 */
    val isInjectionHardStopped: Boolean
        get() = injectionHardStopped.get()
    
    /**
     * 设置无障碍服务
     */
    fun setAccessibilityService(service: AccessibilityService) {
        accessibilityService = service
        Logger.remoteControl("无障碍服务已设置")
    }
    
    /**
     * 开始输入执行
     */
    fun startExecution(config: InputConfig = InputConfig()): Result<Unit> {
        return try {
            Logger.remoteControl("开始输入执行")
            
            if (accessibilityService == null) {
                return Result.failure(IllegalStateException("无障碍服务未设置"))
            }
            
            _executionConfig.value = config
            injectionHardStopped.set(false)
            _isExecutionActive.value = true
            
            // 重置统计
            _executionStats.value = InputEventStats()
            
            Logger.remoteControl("输入执行已启动")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.remoteControl("启动输入执行失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 停止输入执行
     */
    fun stopExecution(): Result<Unit> {
        return try {
            Logger.remoteControl("停止输入执行")
            
            stopAllInjectionNow()
            
            Logger.remoteControl("输入执行已停止")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.remoteControl("停止输入执行失败", e)
            Result.failure(e)
        }
    }

    /**
     * 授权对端并开启注入准入（R6.7）。仅该对端的输入事件会被执行。
     *
     * @param baselineCounter 授权时刻会话上已观察到的信封计数器（会话中途启用注入时必须传入，
     *   否则首个事件会落在接受窗口之外）。
     */
    fun authorizeInjectionPeer(peerId: String, baselineCounter: Long = 0L) {
        admissionGate.startInjection(peerId, baselineCounter)
    }

    /**
     * 本地停止入口（R6.7）：**同步**关闭准入硬门、取消全部在途注入，使触发后立即（远快于 1 秒）
     * 停止全部输入注入；返回前门已关闭，后续事件一律丢弃。幂等。
     */
    fun stopAllInjectionNow() {
        injectionHardStopped.set(true)
        _isExecutionActive.value = false
        admissionGate.stopAllInjection()

        // 取消在途注入（排队中与执行中的手势等待）。
        val pending = inFlightInjections.toList()
        inFlightInjections.clear()
        pending.forEach { job -> job.cancel() }

        Logger.remoteControl("本地停止入口已触发：全部输入注入已停止 (cancelled=${pending.size})")
    }

    /**
     * 经准入门执行远程输入事件（R6.7/R6.8）。
     *
     * 复用既有安全信封计数器（不新增线字段）：仅当注入未被本地停止、对端已授权、会话签名有效、
     * 计数器严格大于本会话已接受最大值且落在 256 事件接受窗口内时才真正注入；否则丢弃、
     * 不改变设备输入状态，并由准入门记录一条含拒绝原因的审计事件。
     */
    suspend fun executeAdmittedInputEvent(
        event: InputEvent,
        envelopeCounter: Long,
        peerId: String,
        signatureValid: Boolean,
        packetType: PacketType = PacketType.CONTROL,
    ): InputEventResponse {
        val startTime = System.currentTimeMillis()

        // 硬门优先：本地停止后立即丢弃，不进入准入统计。
        if (injectionHardStopped.get()) {
            return createErrorResponse(event.eventId, "输入注入已被本地停止", startTime)
        }

        val admission = admissionGate.admit(
            envelopeCounter = envelopeCounter,
            packetType = packetType,
            peerId = peerId,
            signatureValid = signatureValid,
        )

        return when (admission) {
            is Admission.Reject ->
                createErrorResponse(event.eventId, "输入事件被准入门拒绝: ${admission.reason}", startTime)
            is Admission.Accept -> executeInputEvent(event)
        }
    }
    
    /**
     * 执行输入事件
     */
    suspend fun executeInputEvent(event: InputEvent): InputEventResponse {
        val startTime = System.currentTimeMillis()
        
        return try {
            // R6.7 本地停止硬门：置位后一律不注入。
            if (injectionHardStopped.get()) {
                return createErrorResponse(event.eventId, "输入注入已被本地停止", startTime)
            }
            if (!_isExecutionActive.value) {
                return createErrorResponse(event.eventId, "输入执行未启动", startTime)
            }
            
            val success = withRegisteredInjection {
                when (event) {
                    is TouchEvent -> executeTouchEvent(event)
                    is KeyboardEvent -> executeKeyboardEvent(event)
                    is MouseEvent -> executeMouseEvent(event)
                    is GestureEvent -> executeGestureEvent(event)
                    is TextInputEvent -> executeTextInputEvent(event)
                    is SystemKeyEvent -> executeSystemKeyEvent(event)
                }
            }
            
            val processingTime = System.currentTimeMillis() - startTime
            
            val response = InputEventResponse(
                eventId = event.eventId,
                success = success,
                timestamp = System.currentTimeMillis(),
                processingTime = processingTime
            )
            
            // 更新统计
            updateStats(success, processingTime)
            
            // 发送执行结果
            _executionResults.emit(response)
            
            response
            
        } catch (e: CancellationException) {
            // 本地停止取消了在途注入：不再改变设备输入状态。
            Logger.remoteControl("输入注入在途被取消（本地停止）")
            createErrorResponse(event.eventId, "输入注入已被本地停止", startTime)
        } catch (e: Exception) {
            Logger.remoteControl("执行输入事件失败", e)
            val response = createErrorResponse(event.eventId, e.message ?: "执行失败", startTime)
            _executionResults.emit(response)
            response
        }
    }

    /**
     * 把一次注入登记为「在途」，使本地停止入口能取消它（R6.7 的 1 秒停止预算）。
     */
    private suspend fun <T> withRegisteredInjection(block: suspend () -> T): T = coroutineScope {
        val job = coroutineContext[Job]
        if (job != null) inFlightInjections.add(job)
        try {
            block()
        } finally {
            if (job != null) inFlightInjections.remove(job)
        }
    }
    
    /**
     * 执行触摸事件
     */
    private suspend fun executeTouchEvent(event: TouchEvent): Boolean {
        if (!_executionConfig.value.enableTouch) {
            return false
        }
        
        val service = accessibilityService ?: return false
        
        return try {
            val path = Path().apply {
                moveTo(event.x, event.y)
            }
            
            val gesture = when (event.action) {
                TouchAction.DOWN -> {
                    GestureDescription.Builder()
                        .addStroke(GestureDescription.StrokeDescription(path, 0, 100))
                        .build()
                }
                TouchAction.UP -> {
                    GestureDescription.Builder()
                        .addStroke(GestureDescription.StrokeDescription(path, 0, 1))
                        .build()
                }
                TouchAction.MOVE -> {
                    GestureDescription.Builder()
                        .addStroke(GestureDescription.StrokeDescription(path, 0, 50))
                        .build()
                }
                TouchAction.CANCEL -> return true // 取消事件不需要执行
            }
            
            var success = false
            val callback = object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    success = true
                }
                
                override fun onCancelled(gestureDescription: GestureDescription?) {
                    success = false
                }
            }
            
            service.dispatchGesture(gesture, callback, null)

            // 等待手势完成
            delay(200)

            success
            
        } catch (e: Exception) {
            Logger.remoteControl("执行触摸事件失败", e)
            false
        }
    }
    
    /**
     * 执行键盘事件
     */
    @Suppress("DEPRECATION") // ACTION_MULTIPLE deprecated but needed for cross-platform compatibility
    private suspend fun executeKeyboardEvent(event: KeyboardEvent): Boolean {
        if (!_executionConfig.value.enableKeyboard) {
            return false
        }
        
        val service = accessibilityService ?: return false
        
        return try {
            val keyEvent = when (event.action) {
                KeyAction.DOWN -> KeyEvent(
                    event.timestamp,
                    event.timestamp,
                    KeyEvent.ACTION_DOWN,
                    event.keyCode,
                    event.repeatCount,
                    event.metaState
                )
                KeyAction.UP -> KeyEvent(
                    event.timestamp,
                    event.timestamp,
                    KeyEvent.ACTION_UP,
                    event.keyCode,
                    event.repeatCount,
                    event.metaState
                )
                KeyAction.MULTIPLE -> KeyEvent(
                    event.timestamp,
                    event.timestamp,
                    KeyEvent.ACTION_MULTIPLE,
                    event.keyCode,
                    event.repeatCount,
                    event.metaState
                )
            }

            if (isModifierKey(event.keyCode)) {
                return true
            }

            if (event.action != KeyAction.DOWN) {
                return true
            }

            val editableShortcutHandled = handleEditableShortcut(service, event)
            if (editableShortcutHandled) {
                return true
            }

            when (event.keyCode) {
                KeyEvent.KEYCODE_DEL -> deleteFocusedText(service)
                KeyEvent.KEYCODE_FORWARD_DEL -> deleteForwardFocusedText(service)
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER -> handleEnterKey(service)
                KeyEvent.KEYCODE_TAB -> handleTabKey(service, event.metaState)
                KeyEvent.KEYCODE_SPACE -> commitTextToFocusedNode(service, " ")
                KeyEvent.KEYCODE_DPAD_CENTER -> clickFocusedNode(service)
                KeyEvent.KEYCODE_DPAD_LEFT -> moveCursorOrFocus(service, delta = -1, direction = View.FOCUS_LEFT)
                KeyEvent.KEYCODE_DPAD_RIGHT -> moveCursorOrFocus(service, delta = 1, direction = View.FOCUS_RIGHT)
                KeyEvent.KEYCODE_DPAD_UP -> navigateFocus(service, View.FOCUS_UP)
                KeyEvent.KEYCODE_DPAD_DOWN -> navigateFocus(service, View.FOCUS_DOWN)
                KeyEvent.KEYCODE_MOVE_HOME -> moveCursorToBoundary(service, atStart = true)
                KeyEvent.KEYCODE_MOVE_END -> moveCursorToBoundary(service, atStart = false)
                KeyEvent.KEYCODE_PAGE_UP -> scrollFocusedContainer(service, forward = false)
                KeyEvent.KEYCODE_PAGE_DOWN -> scrollFocusedContainer(service, forward = true)
                else -> {
                    val handledShortcut = handleKeyboardShortcut(service, event.keyCode)
                    if (handledShortcut) {
                        true
                    } else {
                        val unicodeChar = keyEvent.unicodeChar
                        if (unicodeChar != 0 && !Character.isISOControl(unicodeChar)) {
                            commitTextToFocusedNode(service, unicodeChar.toChar().toString())
                        } else {
                            false
                        }
                    }
                }
            }
            
        } catch (e: Exception) {
            Logger.remoteControl("执行键盘事件失败", e)
            false
        }
    }
    
    /**
     * 执行鼠标事件
     */
    private suspend fun executeMouseEvent(event: MouseEvent): Boolean {
        if (!_executionConfig.value.enableMouse) {
            return false
        }
        
        // 在Android上，鼠标事件通常转换为触摸事件
        return when (event.action) {
            MouseAction.PRESS -> {
                val touchEvent = TouchEvent(
                    timestamp = event.timestamp,
                    deviceId = event.deviceId,
                    eventId = event.eventId,
                    action = TouchAction.DOWN,
                    x = event.x,
                    y = event.y
                )
                executeTouchEvent(touchEvent)
            }
            MouseAction.RELEASE -> {
                val touchEvent = TouchEvent(
                    timestamp = event.timestamp,
                    deviceId = event.deviceId,
                    eventId = event.eventId,
                    action = TouchAction.UP,
                    x = event.x,
                    y = event.y
                )
                executeTouchEvent(touchEvent)
            }
            MouseAction.MOVE -> {
                val touchEvent = TouchEvent(
                    timestamp = event.timestamp,
                    deviceId = event.deviceId,
                    eventId = event.eventId,
                    action = TouchAction.MOVE,
                    x = event.x,
                    y = event.y
                )
                executeTouchEvent(touchEvent)
            }
            MouseAction.SCROLL -> executeScrollGesture(event.x, event.y, event.scrollX, event.scrollY)
            MouseAction.ENTER, MouseAction.EXIT -> true // 这些事件在Android上不需要特殊处理
        }
    }
    
    /**
     * 执行手势事件
     */
    private suspend fun executeGestureEvent(event: GestureEvent): Boolean {
        if (!_executionConfig.value.enableGesture) {
            return false
        }
        
        val service = accessibilityService ?: return false
        
        return try {
            when (event.gestureType) {
                GestureType.TAP -> executeTapGesture(event.startX, event.startY)
                GestureType.DOUBLE_TAP -> executeDoubleTapGesture(event.startX, event.startY)
                GestureType.LONG_PRESS -> executeLongPressGesture(event.startX, event.startY)
                GestureType.SWIPE -> executeSwipeGesture(event.startX, event.startY, event.endX, event.endY)
                GestureType.PINCH -> executePinchGesture(event.startX, event.startY, event.scale)
                GestureType.ROTATE -> executeRotateGesture(event.startX, event.startY, event.rotation)
                GestureType.FLING -> executeFlingGesture(event.startX, event.startY, event.endX, event.endY, event.velocity)
                GestureType.DRAG -> executeDragGesture(event.startX, event.startY, event.endX, event.endY)
            }
            
        } catch (e: Exception) {
            Logger.remoteControl("执行手势事件失败", e)
            false
        }
    }
    
    /**
     * 执行文本输入事件
     */
    private suspend fun executeTextInputEvent(event: TextInputEvent): Boolean {
        if (!_executionConfig.value.enableTextInput) {
            return false
        }
        
        val service = accessibilityService ?: return false
        
        return try {
            // 找到当前焦点的输入框
            val focusedNode = service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            
            if (focusedNode != null && focusedNode.isEditable) {
                // 设置文本
                val arguments = android.os.Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, event.text)
                }

                focusedNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
                // Note: recycle() is deprecated in API 33+, system handles cleanup automatically
                true
            } else {
                false
            }
            
        } catch (e: Exception) {
            Logger.remoteControl("执行文本输入事件失败", e)
            false
        }
    }
    
    /**
     * 执行系统按键事件
     */
    private suspend fun executeSystemKeyEvent(event: SystemKeyEvent): Boolean {
        if (!_executionConfig.value.enableSystemKeys) {
            return false
        }
        
        val service = accessibilityService ?: return false
        
        return try {
            when (event.systemKey) {
                SystemKey.HOME -> handleKeyboardShortcut(service, KeyEvent.KEYCODE_HOME)
                SystemKey.BACK -> handleKeyboardShortcut(service, KeyEvent.KEYCODE_BACK)
                SystemKey.RECENT_APPS -> handleKeyboardShortcut(service, KeyEvent.KEYCODE_APP_SWITCH)
                SystemKey.NOTIFICATION -> handleKeyboardShortcut(service, KeyEvent.KEYCODE_NOTIFICATION)
                SystemKey.SETTINGS -> handleKeyboardShortcut(service, KeyEvent.KEYCODE_SETTINGS)
                SystemKey.SCREENSHOT -> handleKeyboardShortcut(service, KeyEvent.KEYCODE_SYSRQ)
                SystemKey.VOLUME_UP -> handleKeyboardShortcut(service, KeyEvent.KEYCODE_VOLUME_UP)
                SystemKey.VOLUME_DOWN -> handleKeyboardShortcut(service, KeyEvent.KEYCODE_VOLUME_DOWN)
                SystemKey.VOLUME_MUTE -> handleKeyboardShortcut(service, KeyEvent.KEYCODE_VOLUME_MUTE)
                else -> false // 其他系统按键暂不支持
            }
            
        } catch (e: Exception) {
            Logger.remoteControl("执行系统按键事件失败", e)
            false
        }
    }

    private fun handleKeyboardShortcut(service: AccessibilityService, keyCode: Int): Boolean {
        return when (keyCode) {
            KeyEvent.KEYCODE_BACK,
            KeyEvent.KEYCODE_ESCAPE -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
            KeyEvent.KEYCODE_HOME -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME)
            KeyEvent.KEYCODE_APP_SWITCH -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS)
            KeyEvent.KEYCODE_NOTIFICATION -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS)
            KeyEvent.KEYCODE_SETTINGS -> openQuickSettings(service) || openSystemSettings()
            KeyEvent.KEYCODE_SYSRQ -> takeScreenshot(service)
            KeyEvent.KEYCODE_VOLUME_UP -> adjustVolume(AudioManager.ADJUST_RAISE)
            KeyEvent.KEYCODE_VOLUME_DOWN -> adjustVolume(AudioManager.ADJUST_LOWER)
            KeyEvent.KEYCODE_VOLUME_MUTE -> muteVolume()
            else -> false
        }
    }

    private fun clickFocusedNode(service: AccessibilityService): Boolean {
        val focusedNode = service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: service.rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
            ?: service.rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: return false
        return focusedNode.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    private fun openQuickSettings(service: AccessibilityService): Boolean {
        return service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS)
    }

    private fun takeScreenshot(service: AccessibilityService): Boolean {
        return service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_TAKE_SCREENSHOT)
    }

    private fun openSystemSettings(): Boolean {
        val intent = android.content.Intent(android.provider.Settings.ACTION_SETTINGS).apply {
            flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK
        }
        return runCatching {
            context.startActivity(intent)
            true
        }.getOrDefault(false)
    }

    private fun adjustVolume(direction: Int): Boolean {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
        audioManager.adjustSuggestedStreamVolume(direction, AudioManager.STREAM_MUSIC, AudioManager.FLAG_SHOW_UI)
        return true
    }

    private fun muteVolume(): Boolean {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
        audioManager.adjustSuggestedStreamVolume(
            AudioManager.ADJUST_TOGGLE_MUTE,
            AudioManager.STREAM_MUSIC,
            AudioManager.FLAG_SHOW_UI
        )
        return true
    }
    
    /**
     * 执行点击手势
     */
    private suspend fun executeTapGesture(x: Float, y: Float): Boolean {
        val service = accessibilityService ?: return false
        
        return try {
            val path = Path().apply { moveTo(x, y) }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, 100))
                .build()
            
            var success = false
            val callback = object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    success = true
                }
            }
            
            service.dispatchGesture(gesture, callback, null)
            delay(200)

            success
            
        } catch (e: Exception) {
            Logger.remoteControl("执行点击手势失败", e)
            false
        }
    }
    
    /**
     * 执行双击手势
     */
    private suspend fun executeDoubleTapGesture(x: Float, y: Float): Boolean {
        return executeTapGesture(x, y) && 
               delay(100).let { executeTapGesture(x, y) }
    }
    
    /**
     * 执行长按手势
     */
    private suspend fun executeLongPressGesture(x: Float, y: Float): Boolean {
        val service = accessibilityService ?: return false
        
        return try {
            val path = Path().apply { moveTo(x, y) }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, 1000)) // 长按1秒
                .build()
            
            var success = false
            val callback = object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    success = true
                }
            }
            
            service.dispatchGesture(gesture, callback, null)
            delay(1200)

            success
            
        } catch (e: Exception) {
            Logger.remoteControl("执行长按手势失败", e)
            false
        }
    }
    
    /**
     * 执行滑动手势
     */
    private suspend fun executeSwipeGesture(startX: Float, startY: Float, endX: Float, endY: Float): Boolean {
        val service = accessibilityService ?: return false
        
        return try {
            val path = Path().apply {
                moveTo(startX, startY)
                lineTo(endX, endY)
            }
            
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, 300))
                .build()
            
            var success = false
            val callback = object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    success = true
                }
            }
            
            service.dispatchGesture(gesture, callback, null)
            delay(400)

            success
            
        } catch (e: Exception) {
            Logger.remoteControl("执行滑动手势失败", e)
            false
        }
    }
    
    /**
     * 执行捏合手势
     */
    private suspend fun executePinchGesture(centerX: Float, centerY: Float, scale: Float): Boolean {
        val service = accessibilityService ?: return false

        return try {
            // Treat scale > 1 as zoom-out (fingers move apart), scale < 1 as pinch-in.
            val clampedScale = scale.coerceIn(0.2f, 5.0f)
            val baseDistance = 200f
            val startHalf = baseDistance / 2f
            val endHalf = (baseDistance * clampedScale) / 2f

            val start1X = centerX - startHalf
            val start2X = centerX + startHalf
            val end1X = centerX - endHalf
            val end2X = centerX + endHalf

            val path1 = Path().apply {
                moveTo(start1X, centerY)
                lineTo(end1X, centerY)
            }
            val path2 = Path().apply {
                moveTo(start2X, centerY)
                lineTo(end2X, centerY)
            }

            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path1, 0, 300))
                .addStroke(GestureDescription.StrokeDescription(path2, 0, 300))
                .build()

            var success = false
            val callback = object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    success = true
                }
            }

            service.dispatchGesture(gesture, callback, null)
            delay(400)
            success
        } catch (e: Exception) {
            Logger.remoteControl("执行捏合手势失败", e)
            false
        }
    }
    
    /**
     * 执行旋转手势
     */
    private suspend fun executeRotateGesture(centerX: Float, centerY: Float, rotation: Float): Boolean {
        val service = accessibilityService ?: return false

        return try {
            // Interpret rotation as degrees (positive = clockwise).
            val deltaRad = Math.toRadians(rotation.toDouble()).toFloat()
            val radius = 120f

            // Two fingers opposite each other.
            val startAngle1 = 0f
            val startAngle2 = Math.PI.toFloat()
            val endAngle1 = startAngle1 + deltaRad
            val endAngle2 = startAngle2 + deltaRad

            fun point(angle: Float): Pair<Float, Float> {
                val x = centerX + radius * kotlin.math.cos(angle)
                val y = centerY + radius * kotlin.math.sin(angle)
                return x to y
            }

            val (s1x, s1y) = point(startAngle1)
            val (e1x, e1y) = point(endAngle1)
            val (s2x, s2y) = point(startAngle2)
            val (e2x, e2y) = point(endAngle2)

            val path1 = Path().apply {
                moveTo(s1x, s1y)
                lineTo(e1x, e1y)
            }
            val path2 = Path().apply {
                moveTo(s2x, s2y)
                lineTo(e2x, e2y)
            }

            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path1, 0, 350))
                .addStroke(GestureDescription.StrokeDescription(path2, 0, 350))
                .build()

            var success = false
            val callback = object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    success = true
                }
            }

            service.dispatchGesture(gesture, callback, null)
            delay(450)
            success
        } catch (e: Exception) {
            Logger.remoteControl("执行旋转手势失败", e)
            false
        }
    }
    
    /**
     * 执行快速滑动手势
     */
    private suspend fun executeFlingGesture(startX: Float, startY: Float, endX: Float, endY: Float, velocity: Float): Boolean {
        // 快速滑动与普通滑动类似，但持续时间更短
        return executeSwipeGesture(startX, startY, endX, endY)
    }
    
    /**
     * 执行拖拽手势
     */
    private suspend fun executeDragGesture(startX: Float, startY: Float, endX: Float, endY: Float): Boolean {
        // 拖拽与滑动类似，但持续时间更长
        val service = accessibilityService ?: return false
        
        return try {
            val path = Path().apply {
                moveTo(startX, startY)
                lineTo(endX, endY)
            }
            
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, 800)) // 拖拽时间更长
                .build()
            
            var success = false
            val callback = object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    success = true
                }
            }
            
            service.dispatchGesture(gesture, callback, null)
            delay(900)

            success
            
        } catch (e: Exception) {
            Logger.remoteControl("执行拖拽手势失败", e)
            false
        }
    }
    
    /**
     * 执行滚动手势
     */
    private suspend fun executeScrollGesture(x: Float, y: Float, scrollX: Float, scrollY: Float): Boolean {
        // 滚动转换为滑动手势
        val endX = x + scrollX * 100 // 放大滚动距离
        val endY = y + scrollY * 100
        
        return executeSwipeGesture(x, y, endX, endY)
    }
    
    /**
     * 创建错误响应
     */
    private fun createErrorResponse(eventId: String, errorMessage: String, startTime: Long): InputEventResponse {
        return InputEventResponse(
            eventId = eventId,
            success = false,
            errorMessage = errorMessage,
            timestamp = System.currentTimeMillis(),
            processingTime = System.currentTimeMillis() - startTime
        )
    }
    
    /**
     * 更新统计信息
     */
    private fun updateStats(success: Boolean, processingTime: Long) {
        _executionStats.value = _executionStats.value.let { stats ->
            InputExecutionStatsReducer.record(
                stats = stats,
                success = success,
                processingTime = processingTime,
                now = System.currentTimeMillis()
            )
        }
    }
    
    /**
     * 更新执行配置
     */
    fun updateConfig(config: InputConfig) {
        _executionConfig.value = config
        Logger.remoteControl("执行配置已更新")
    }
    
    /**
     * 检查无障碍服务是否可用
     */
    fun isAccessibilityServiceAvailable(): Boolean {
        return accessibilityService != null
    }

    private suspend fun handleEditableShortcut(
        service: AccessibilityService,
        event: KeyboardEvent
    ): Boolean {
        if (!hasPrimaryCommandModifier(event.metaState)) return false

        return when (event.keyCode) {
            KeyEvent.KEYCODE_A -> selectAllFocusedText(service)
            KeyEvent.KEYCODE_C -> performFocusedTextAction(service, AccessibilityNodeInfo.ACTION_COPY)
            KeyEvent.KEYCODE_X -> performFocusedTextAction(service, AccessibilityNodeInfo.ACTION_CUT)
            KeyEvent.KEYCODE_V -> performFocusedTextAction(service, AccessibilityNodeInfo.ACTION_PASTE)
            else -> false
        }
    }

    private suspend fun commitTextToFocusedNode(
        service: AccessibilityService,
        text: String
    ): Boolean {
        val focusedNode = focusedEditableNode(service) ?: return false
        return withContext(Dispatchers.Main) {
            val currentText = focusedNode.text?.toString().orEmpty()
            val start = (focusedNode.textSelectionStart.takeIf { it >= 0 } ?: currentText.length)
                .coerceIn(0, currentText.length)
            val end = (focusedNode.textSelectionEnd.takeIf { it >= 0 } ?: start)
                .coerceIn(0, currentText.length)
            val from = minOf(start, end)
            val to = maxOf(start, end)
            val updatedText = buildString(currentText.length - (to - from) + text.length) {
                append(currentText.substring(0, from))
                append(text)
                append(currentText.substring(to))
            }
            val arguments = android.os.Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    updatedText
                )
            }
            if (!focusedNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)) {
                return@withContext false
            }
            val newCursor = from + text.length
            setSelection(focusedNode, newCursor, newCursor)
        }
    }

    private suspend fun deleteFocusedText(service: AccessibilityService): Boolean {
        val focusedNode = focusedEditableNode(service) ?: return false
        return withContext(Dispatchers.Main) {
            val currentText = focusedNode.text?.toString().orEmpty()
            val start = (focusedNode.textSelectionStart.takeIf { it >= 0 } ?: currentText.length)
                .coerceIn(0, currentText.length)
            val end = (focusedNode.textSelectionEnd.takeIf { it >= 0 } ?: start)
                .coerceIn(0, currentText.length)
            val from = minOf(start, end)
            val to = maxOf(start, end)
            val updatedText = when {
                from != to -> currentText.removeRange(from, to)
                from > 0 -> currentText.removeRange(from - 1, from)
                else -> currentText
            }
            if (currentText == updatedText) {
                false
            } else {
                val arguments = android.os.Bundle().apply {
                    putCharSequence(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                        updatedText
                    )
                }
                if (!focusedNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)) {
                    return@withContext false
                }
                val newCursor = if (from != to) from else (from - 1).coerceAtLeast(0)
                setSelection(focusedNode, newCursor, newCursor)
            }
        }
    }

    private suspend fun deleteForwardFocusedText(service: AccessibilityService): Boolean {
        val focusedNode = focusedEditableNode(service) ?: return false
        return withContext(Dispatchers.Main) {
            val currentText = focusedNode.text?.toString().orEmpty()
            val start = (focusedNode.textSelectionStart.takeIf { it >= 0 } ?: currentText.length)
                .coerceIn(0, currentText.length)
            val end = (focusedNode.textSelectionEnd.takeIf { it >= 0 } ?: start)
                .coerceIn(0, currentText.length)
            val from = minOf(start, end)
            val to = maxOf(start, end)
            val updatedText = when {
                from != to -> currentText.removeRange(from, to)
                to < currentText.length -> currentText.removeRange(to, to + 1)
                else -> currentText
            }
            if (currentText == updatedText) {
                false
            } else {
                val arguments = android.os.Bundle().apply {
                    putCharSequence(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                        updatedText
                    )
                }
                if (!focusedNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)) {
                    return@withContext false
                }
                setSelection(focusedNode, from, from)
            }
        }
    }

    private suspend fun handleEnterKey(service: AccessibilityService): Boolean {
        return if (focusedEditableNode(service) != null) {
            commitTextToFocusedNode(service, "\n")
        } else {
            clickFocusedNode(service)
        }
    }

    private suspend fun handleTabKey(service: AccessibilityService, metaState: Int): Boolean {
        return if (focusedEditableNode(service) != null) {
            commitTextToFocusedNode(service, "\t")
        } else {
            val direction = if (metaState and KeyEvent.META_SHIFT_ON != 0) {
                View.FOCUS_BACKWARD
            } else {
                View.FOCUS_FORWARD
            }
            navigateFocus(service, direction)
        }
    }

    private suspend fun moveCursorOrFocus(
        service: AccessibilityService,
        delta: Int,
        direction: Int
    ): Boolean {
        val focusedNode = focusedEditableNode(service)
        if (focusedNode == null) {
            return navigateFocus(service, direction)
        }
        return withContext(Dispatchers.Main) {
            val currentText = focusedNode.text?.toString().orEmpty()
            val selectionStart = (focusedNode.textSelectionStart.takeIf { it >= 0 } ?: currentText.length)
                .coerceIn(0, currentText.length)
            val selectionEnd = (focusedNode.textSelectionEnd.takeIf { it >= 0 } ?: selectionStart)
                .coerceIn(0, currentText.length)
            val base = if (delta < 0) minOf(selectionStart, selectionEnd) else maxOf(selectionStart, selectionEnd)
            val next = (base + delta).coerceIn(0, currentText.length)
            setSelection(focusedNode, next, next)
        }
    }

    private suspend fun moveCursorToBoundary(
        service: AccessibilityService,
        atStart: Boolean
    ): Boolean {
        val focusedNode = focusedEditableNode(service) ?: return false
        return withContext(Dispatchers.Main) {
            val currentText = focusedNode.text?.toString().orEmpty()
            val target = if (atStart) 0 else currentText.length
            setSelection(focusedNode, target, target)
        }
    }

    private suspend fun scrollFocusedContainer(
        service: AccessibilityService,
        forward: Boolean
    ): Boolean = withContext(Dispatchers.Main) {
        val root = service.rootInActiveWindow ?: return@withContext false
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
            ?: root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: root
        val action = if (forward) {
            AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        } else {
            AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        }
        focused.performAction(action)
    }

    private suspend fun navigateFocus(service: AccessibilityService, direction: Int): Boolean =
        withContext(Dispatchers.Main) {
            val root = service.rootInActiveWindow ?: return@withContext false
            val current = root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
                ?: root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                ?: root
            val next = current.focusSearch(direction) ?: return@withContext false
            next.performAction(AccessibilityNodeInfo.ACTION_FOCUS) ||
                next.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
        }

    private suspend fun selectAllFocusedText(service: AccessibilityService): Boolean {
        val focusedNode = focusedEditableNode(service) ?: return false
        return withContext(Dispatchers.Main) {
            val currentText = focusedNode.text?.toString().orEmpty()
            setSelection(focusedNode, 0, currentText.length)
        }
    }

    private suspend fun performFocusedTextAction(
        service: AccessibilityService,
        action: Int
    ): Boolean {
        val focusedNode = focusedEditableNode(service) ?: return false
        return withContext(Dispatchers.Main) {
            focusedNode.performAction(action)
        }
    }

    private fun focusedEditableNode(service: AccessibilityService): AccessibilityNodeInfo? {
        val direct = service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (direct?.isEditable == true) return direct

        val root = service.rootInActiveWindow ?: return null
        val accessibilityFocus = root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
        if (accessibilityFocus?.isEditable == true) return accessibilityFocus

        val inputFocus = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (inputFocus?.isEditable == true) return inputFocus

        return null
    }

    private fun setSelection(node: AccessibilityNodeInfo, start: Int, end: Int): Boolean {
        val args = android.os.Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
    }

    private fun hasPrimaryCommandModifier(metaState: Int): Boolean {
        return metaState and (KeyEvent.META_CTRL_ON or KeyEvent.META_META_ON) != 0
    }

    private fun isModifierKey(keyCode: Int): Boolean {
        return when (keyCode) {
            KeyEvent.KEYCODE_SHIFT_LEFT,
            KeyEvent.KEYCODE_SHIFT_RIGHT,
            KeyEvent.KEYCODE_CTRL_LEFT,
            KeyEvent.KEYCODE_CTRL_RIGHT,
            KeyEvent.KEYCODE_ALT_LEFT,
            KeyEvent.KEYCODE_ALT_RIGHT,
            KeyEvent.KEYCODE_META_LEFT,
            KeyEvent.KEYCODE_META_RIGHT,
            KeyEvent.KEYCODE_CAPS_LOCK,
            KeyEvent.KEYCODE_FUNCTION -> true

            else -> false
        }
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        scope.launch {
            try {
                Logger.remoteControl("清理输入执行资源")
                
                stopExecution()
                accessibilityService = null
                
                Logger.remoteControl("输入执行资源清理完成")
                
            } catch (e: Exception) {
                Logger.remoteControl("清理输入执行资源失败", e)
            }
        }
    }
}

internal object InputExecutionStatsReducer {
    fun record(
        stats: InputEventStats,
        success: Boolean,
        processingTime: Long,
        now: Long
    ): InputEventStats {
        val nextTotal = stats.totalEvents + 1
        val averageLatency =
            ((stats.averageLatency * stats.totalEvents.coerceAtLeast(0)) + processingTime) / nextTotal
        return stats.copy(
            totalEvents = nextTotal,
            successfulEvents = if (success) stats.successfulEvents + 1 else stats.successfulEvents,
            failedEvents = if (!success) stats.failedEvents + 1 else stats.failedEvents,
            averageLatency = averageLatency,
            lastEventTime = now
        )
    }
}
