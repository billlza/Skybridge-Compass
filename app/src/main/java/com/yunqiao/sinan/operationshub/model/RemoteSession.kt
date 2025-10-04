package com.yunqiao.sinan.operationshub.model

/**
 * 远程会话数据类
 */
data class RemoteSession(
    /** 会话 ID */
    val sessionId: String,
    
    /** 设备名称 */
    val deviceName: String,
    
    /** 设备 IP 地址 */
    val deviceIp: String,
    
    /** 会话状态 */
    val status: RemoteConnectionStatus,
    
    /** 开始时间 */
    val startTime: Long,
    
    /** 分辨率宽度 */
    val width: Int = 1920,
    
    /** 分辨率高度 */
    val height: Int = 1080,
    
    /** 用户名 */
    val username: String? = null,
    
    /** 连接类型 */
    val connectionType: String = "RDP"
)
