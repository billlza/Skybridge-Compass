package com.skybridge.compass.remotecontrol.capture

import android.content.Context
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.remotecontrol.model.*
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * 输入捕获管理器
 * 负责捕获各种输入事件并转换为标准格式
 */
@Singleton
class InputCaptureManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    
    // 输入事件流
    private val _inputEvents = MutableSharedFlow<InputEvent>()
    val inputEvents: SharedFlow<InputEvent> = _inputEvents.asSharedFlow()
    
    // 输入配置
    private val _inputConfig = MutableStateFlow(InputConfig())
    val inputConfig: StateFlow<InputConfig> = _inputConfig.asStateFlow()
    
    // 捕获状态
    private val _isCaptureActive = MutableStateFlow(false)
    val isCaptureActive: StateFlow<Boolean> = _isCaptureActive.asStateFlow()
    
    // 手势检测器
    private var gestureDetector: GestureDetector? = null
    
    // 触摸状态跟踪
    private val activeTouches = mutableMapOf<Int, TouchState>()
    
    // 输入统计
    private val _inputStats = MutableStateFlow(InputEventStats())
    val inputStats: StateFlow<InputEventStats> = _inputStats.asStateFlow()
    
    // 事件批次处理
    private val eventBatch = mutableListOf<InputEvent>()
    private var batchJob: Job? = null
    
    /**
     * 触摸状态
     */
    private data class TouchState(
        val pointerId: Int,
        val startX: Float,
        val startY: Float,
        val lastX: Float,
        val lastY: Float,
        val startTime: Long,
        val lastTime: Long
    )
    
    init {
        initializeGestureDetector()
        startBatchProcessing()
    }
    
    /**
     * 初始化手势检测器
     */
    private fun initializeGestureDetector() {
        gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
            
            override fun onSingleTapUp(e: MotionEvent): Boolean {
                if (_inputConfig.value.enableGesture) {
                    emitGestureEvent(
                        GestureType.TAP,
                        e.x, e.y, e.x, e.y
                    )
                }
                return true
            }
            
            override fun onDoubleTap(e: MotionEvent): Boolean {
                if (_inputConfig.value.enableGesture) {
                    emitGestureEvent(
                        GestureType.DOUBLE_TAP,
                        e.x, e.y, e.x, e.y
                    )
                }
                return true
            }
            
            override fun onLongPress(e: MotionEvent) {
                if (_inputConfig.value.enableGesture) {
                    emitGestureEvent(
                        GestureType.LONG_PRESS,
                        e.x, e.y, e.x, e.y
                    )
                }
            }
            
            override fun onFling(
                e1: MotionEvent?,
                e2: MotionEvent,
                velocityX: Float,
                velocityY: Float
            ): Boolean {
                if (_inputConfig.value.enableGesture && e1 != null) {
                    val velocity = sqrt(velocityX * velocityX + velocityY * velocityY)
                    emitGestureEvent(
                        GestureType.FLING,
                        e1.x, e1.y, e2.x, e2.y,
                        velocity = velocity
                    )
                }
                return true
            }
            
            override fun onScroll(
                e1: MotionEvent?,
                e2: MotionEvent,
                distanceX: Float,
                distanceY: Float
            ): Boolean {
                if (_inputConfig.value.enableGesture && e1 != null) {
                    val distance = sqrt(distanceX * distanceX + distanceY * distanceY)
                    if (distance > _inputConfig.value.gestureThreshold) {
                        emitGestureEvent(
                            GestureType.SWIPE,
                            e1.x, e1.y, e2.x, e2.y
                        )
                    }
                }
                return true
            }
        })
    }
    
    /**
     * 开始输入捕获
     */
    fun startCapture(config: InputConfig = InputConfig()): Result<Unit> {
        return try {
            Logger.remoteControl("开始输入捕获")
            
            _inputConfig.value = config
            _isCaptureActive.value = true
            
            // 重置统计
            _inputStats.value = InputEventStats()
            
            Logger.remoteControl("输入捕获已启动")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.remoteControl("启动输入捕获失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 停止输入捕获
     */
    fun stopCapture(): Result<Unit> {
        return try {
            Logger.remoteControl("停止输入捕获")
            
            _isCaptureActive.value = false
            activeTouches.clear()
            eventBatch.clear()
            batchJob?.cancel()
            
            Logger.remoteControl("输入捕获已停止")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.remoteControl("停止输入捕获失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 处理触摸事件
     */
    fun handleTouchEvent(event: MotionEvent, deviceId: String): Boolean {
        if (!_isCaptureActive.value || !_inputConfig.value.enableTouch) {
            return false
        }
        
        try {
            // 让手势检测器先处理
            gestureDetector?.onTouchEvent(event)
            
            val action = event.actionMasked
            val pointerIndex = event.actionIndex
            val pointerId = event.getPointerId(pointerIndex)
            
            when (action) {
                MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                    handleTouchDown(event, pointerIndex, pointerId, deviceId)
                }
                
                MotionEvent.ACTION_MOVE -> {
                    handleTouchMove(event, deviceId)
                }
                
                MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                    handleTouchUp(event, pointerIndex, pointerId, deviceId)
                }
                
                MotionEvent.ACTION_CANCEL -> {
                    handleTouchCancel(event, deviceId)
                }
            }
            
            return true
            
        } catch (e: Exception) {
            Logger.remoteControl("处理触摸事件失败", e)
            return false
        }
    }
    
    /**
     * 处理触摸按下
     */
    private fun handleTouchDown(
        event: MotionEvent,
        pointerIndex: Int,
        pointerId: Int,
        deviceId: String
    ) {
        val x = event.getX(pointerIndex) * _inputConfig.value.touchSensitivity
        val y = event.getY(pointerIndex) * _inputConfig.value.touchSensitivity
        val pressure = event.getPressure(pointerIndex)
        val size = event.getSize(pointerIndex)
        
        // 记录触摸状态
        activeTouches[pointerId] = TouchState(
            pointerId = pointerId,
            startX = x,
            startY = y,
            lastX = x,
            lastY = y,
            startTime = event.eventTime,
            lastTime = event.eventTime
        )
        
        // 发送触摸事件
        emitTouchEvent(
            deviceId = deviceId,
            action = TouchAction.DOWN,
            x = x,
            y = y,
            pressure = pressure,
            pointerId = pointerId,
            size = size
        )
    }
    
    /**
     * 处理触摸移动
     */
    private fun handleTouchMove(event: MotionEvent, deviceId: String) {
        for (i in 0 until event.pointerCount) {
            val pointerId = event.getPointerId(i)
            val touchState = activeTouches[pointerId] ?: continue
            
            val x = event.getX(i) * _inputConfig.value.touchSensitivity
            val y = event.getY(i) * _inputConfig.value.touchSensitivity
            val pressure = event.getPressure(i)
            val size = event.getSize(i)
            
            // 更新触摸状态
            activeTouches[pointerId] = touchState.copy(
                lastX = x,
                lastY = y,
                lastTime = event.eventTime
            )
            
            // 发送触摸事件
            emitTouchEvent(
                deviceId = deviceId,
                action = TouchAction.MOVE,
                x = x,
                y = y,
                pressure = pressure,
                pointerId = pointerId,
                size = size
            )
        }
    }
    
    /**
     * 处理触摸抬起
     */
    private fun handleTouchUp(
        event: MotionEvent,
        pointerIndex: Int,
        pointerId: Int,
        deviceId: String
    ) {
        val x = event.getX(pointerIndex) * _inputConfig.value.touchSensitivity
        val y = event.getY(pointerIndex) * _inputConfig.value.touchSensitivity
        val pressure = event.getPressure(pointerIndex)
        val size = event.getSize(pointerIndex)
        
        // 移除触摸状态
        activeTouches.remove(pointerId)
        
        // 发送触摸事件
        emitTouchEvent(
            deviceId = deviceId,
            action = TouchAction.UP,
            x = x,
            y = y,
            pressure = pressure,
            pointerId = pointerId,
            size = size
        )
    }
    
    /**
     * 处理触摸取消
     */
    private fun handleTouchCancel(event: MotionEvent, deviceId: String) {
        for (i in 0 until event.pointerCount) {
            val pointerId = event.getPointerId(i)
            val x = event.getX(i) * _inputConfig.value.touchSensitivity
            val y = event.getY(i) * _inputConfig.value.touchSensitivity
            
            emitTouchEvent(
                deviceId = deviceId,
                action = TouchAction.CANCEL,
                x = x,
                y = y,
                pointerId = pointerId
            )
        }
        
        activeTouches.clear()
    }
    
    /**
     * 处理键盘事件
     */
    fun handleKeyEvent(
        keyCode: Int,
        action: KeyAction,
        metaState: Int,
        deviceId: String
    ): Boolean {
        if (!_isCaptureActive.value || !_inputConfig.value.enableKeyboard) {
            return false
        }
        
        try {
            emitKeyboardEvent(
                deviceId = deviceId,
                action = action,
                keyCode = keyCode,
                metaState = metaState
            )
            return true
            
        } catch (e: Exception) {
            Logger.remoteControl("处理键盘事件失败", e)
            return false
        }
    }
    
    /**
     * 处理文本输入
     */
    fun handleTextInput(text: String, deviceId: String): Boolean {
        if (!_isCaptureActive.value || !_inputConfig.value.enableTextInput) {
            return false
        }
        
        try {
            emitTextInputEvent(deviceId, text)
            return true
            
        } catch (e: Exception) {
            Logger.remoteControl("处理文本输入失败", e)
            return false
        }
    }
    
    /**
     * 处理系统按键
     */
    fun handleSystemKey(systemKey: SystemKey, action: KeyAction, deviceId: String): Boolean {
        if (!_isCaptureActive.value || !_inputConfig.value.enableSystemKeys) {
            return false
        }
        
        try {
            emitSystemKeyEvent(deviceId, systemKey, action)
            return true
            
        } catch (e: Exception) {
            Logger.remoteControl("处理系统按键失败", e)
            return false
        }
    }
    
    /**
     * 发送触摸事件
     */
    private fun emitTouchEvent(
        deviceId: String,
        action: TouchAction,
        x: Float,
        y: Float,
        pressure: Float = 1.0f,
        pointerId: Int = 0,
        size: Float = 1.0f
    ) {
        val event = InputEventUtils.createTouchEvent(
            deviceId = deviceId,
            action = action,
            x = x,
            y = y,
            pressure = pressure
        ).copy(pointerId = pointerId, size = size)
        
        addEventToBatch(event)
        updateStats { it.copy(touchEvents = it.touchEvents + 1) }
    }
    
    /**
     * 发送键盘事件
     */
    private fun emitKeyboardEvent(
        deviceId: String,
        action: KeyAction,
        keyCode: Int,
        metaState: Int = 0
    ) {
        val event = InputEventUtils.createKeyboardEvent(
            deviceId = deviceId,
            action = action,
            keyCode = keyCode,
            metaState = metaState
        )
        
        addEventToBatch(event)
        updateStats { it.copy(keyboardEvents = it.keyboardEvents + 1) }
    }
    
    /**
     * 发送手势事件
     */
    private fun emitGestureEvent(
        gestureType: GestureType,
        startX: Float,
        startY: Float,
        endX: Float,
        endY: Float,
        scale: Float = 1.0f,
        rotation: Float = 0f,
        velocity: Float = 0f
    ) {
        val deviceId = "local" // 本地设备ID
        val duration = System.currentTimeMillis() - (activeTouches.values.firstOrNull()?.startTime ?: 0L)
        
        val event = InputEventUtils.createGestureEvent(
            deviceId = deviceId,
            gestureType = gestureType,
            startX = startX,
            startY = startY,
            endX = endX,
            endY = endY
        ).copy(
            scale = scale,
            rotation = rotation,
            velocity = velocity,
            duration = duration
        )
        
        addEventToBatch(event)
        updateStats { it.copy(gestureEvents = it.gestureEvents + 1) }
    }
    
    /**
     * 发送文本输入事件
     */
    private fun emitTextInputEvent(deviceId: String, text: String) {
        val event = InputEventUtils.createTextInputEvent(deviceId, text)
        addEventToBatch(event)
        updateStats { it.copy(textInputEvents = it.textInputEvents + 1) }
    }
    
    /**
     * 发送系统按键事件
     */
    private fun emitSystemKeyEvent(deviceId: String, systemKey: SystemKey, action: KeyAction) {
        val event = InputEventUtils.createSystemKeyEvent(deviceId, systemKey, action)
        addEventToBatch(event)
        updateStats { it.copy(systemKeyEvents = it.systemKeyEvents + 1) }
    }
    
    /**
     * 添加事件到批次
     */
    private fun addEventToBatch(event: InputEvent) {
        synchronized(eventBatch) {
            eventBatch.add(event)
            
            // 如果批次已满，立即发送
            if (eventBatch.size >= _inputConfig.value.maxBatchSize) {
                flushEventBatch()
            }
        }
    }
    
    /**
     * 开始批次处理
     */
    private fun startBatchProcessing() {
        batchJob = scope.launch {
            while (isActive) {
                delay(_inputConfig.value.batchTimeout)
                flushEventBatch()
            }
        }
    }
    
    /**
     * 刷新事件批次
     */
    private fun flushEventBatch() {
        synchronized(eventBatch) {
            if (eventBatch.isNotEmpty()) {
                // 发送单个事件（为了简化，这里逐个发送）
                eventBatch.forEach { event ->
                    scope.launch {
                        _inputEvents.emit(event)
                    }
                }
                
                updateStats { stats ->
                    stats.copy(
                        totalEvents = stats.totalEvents + eventBatch.size,
                        lastEventTime = System.currentTimeMillis()
                    )
                }
                
                eventBatch.clear()
            }
        }
    }
    
    /**
     * 更新统计信息
     */
    private fun updateStats(update: (InputEventStats) -> InputEventStats) {
        _inputStats.value = update(_inputStats.value)
    }
    
    /**
     * 更新输入配置
     */
    fun updateConfig(config: InputConfig) {
        _inputConfig.value = config
        Logger.remoteControl("输入配置已更新")
    }
    
    /**
     * 获取当前活跃的触摸点数量
     */
    fun getActiveTouchCount(): Int = activeTouches.size
    
    /**
     * 清理资源
     */
    fun cleanup() {
        scope.launch {
            try {
                Logger.remoteControl("清理输入捕获资源")
                
                stopCapture()
                batchJob?.cancel()
                activeTouches.clear()
                eventBatch.clear()
                
                Logger.remoteControl("输入捕获资源清理完成")
                
            } catch (e: Exception) {
                Logger.remoteControl("清理输入捕获资源失败", e)
            }
        }
    }
}