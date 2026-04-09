package com.skybridge.compass.remotecontrol.service

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.view.accessibility.AccessibilityEvent
import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.remotecontrol.execution.InputExecutionManager
import com.skybridge.compass.remotecontrol.transmission.RemoteControlTransmissionManager
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import javax.inject.Inject

/**
 * 远程控制无障碍服务
 * 提供系统级输入事件执行能力
 */
@AndroidEntryPoint
class RemoteControlAccessibilityService : AccessibilityService() {
    
    @Inject
    lateinit var inputExecutionManager: InputExecutionManager
    
    @Inject
    lateinit var transmissionManager: RemoteControlTransmissionManager
    
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    
    override fun onServiceConnected() {
        super.onServiceConnected()
        
        try {
            Logger.remoteControl("远程控制无障碍服务已连接")
            
            // 设置无障碍服务引用
            inputExecutionManager.setAccessibilityService(this)
            
            // 启动传输管理器
            transmissionManager.startTransmission()
            
            // 监听接收到的输入事件
            serviceScope.launch {
                transmissionManager.receivedInputEvents.collect { inputEvent ->
                    // 执行输入事件
                    val response = inputExecutionManager.executeInputEvent(inputEvent)
                    
                    // 发送响应
                    transmissionManager.sendInputEventResponse(inputEvent.deviceId, response)
                }
            }
            
            // 监听接收到的输入事件批次
            serviceScope.launch {
                transmissionManager.receivedInputBatches.collect { batch ->
                    // 执行批次中的每个事件
                    batch.events.forEach { inputEvent ->
                        val response = inputExecutionManager.executeInputEvent(inputEvent)
                        transmissionManager.sendInputEventResponse(inputEvent.deviceId, response)
                    }
                }
            }
            
            Logger.remoteControl("远程控制服务初始化完成")
            
        } catch (e: Exception) {
            Logger.remoteControl("远程控制无障碍服务连接失败", e)
        }
    }
    
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 这里可以监听系统的无障碍事件，用于调试或其他用途
        // 对于远程控制功能，我们主要关注输入事件的执行，而不是监听
    }
    
    override fun onInterrupt() {
        Logger.remoteControl("远程控制无障碍服务被中断")
    }
    
    override fun onDestroy() {
        super.onDestroy()
        
        try {
            Logger.remoteControl("远程控制无障碍服务正在销毁")
            
            // 停止传输管理器
            transmissionManager.stopTransmission()
            
            // 清理资源
            inputExecutionManager.cleanup()
            transmissionManager.cleanup()
            
            // 取消协程作用域
            serviceScope.cancel()
            
            Logger.remoteControl("远程控制无障碍服务已销毁")
            
        } catch (e: Exception) {
            Logger.remoteControl("销毁远程控制无障碍服务失败", e)
        }
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Logger.remoteControl("远程控制无障碍服务启动命令: ${intent?.action}")
        
        when (intent?.action) {
            ACTION_START_REMOTE_CONTROL -> {
                startRemoteControl()
            }
            ACTION_STOP_REMOTE_CONTROL -> {
                stopRemoteControl()
            }
        }
        
        return START_STICKY
    }
    
    /**
     * 启动远程控制
     */
    private fun startRemoteControl() {
        serviceScope.launch {
            try {
                Logger.remoteControl("启动远程控制")
                
                // 启动输入执行
                inputExecutionManager.startExecution()
                
                Logger.remoteControl("远程控制已启动")
                
            } catch (e: Exception) {
                Logger.remoteControl("启动远程控制失败", e)
            }
        }
    }
    
    /**
     * 停止远程控制
     */
    private fun stopRemoteControl() {
        serviceScope.launch {
            try {
                Logger.remoteControl("停止远程控制")
                
                // 停止输入执行
                inputExecutionManager.stopExecution()
                
                Logger.remoteControl("远程控制已停止")
                
            } catch (e: Exception) {
                Logger.remoteControl("停止远程控制失败", e)
            }
        }
    }
    
    companion object {
        const val ACTION_START_REMOTE_CONTROL = "com.skybridge.compass.remotecontrol.START"
        const val ACTION_STOP_REMOTE_CONTROL = "com.skybridge.compass.remotecontrol.STOP"
    }
}