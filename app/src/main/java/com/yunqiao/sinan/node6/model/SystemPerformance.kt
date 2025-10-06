package com.yunqiao.sinan.node6.model

/**
 * 系统性能数据类
 */
data class SystemPerformance(
    /** 时间戳 */
    val timestamp: Long = 0L,
    
    /** CPU使用率 (0.0-1.0) */
    val cpuUsage: Float = 0f,
    
    /** 内存使用率 (0.0-1.0) */
    val memoryUsage: Float = 0f,
    
    /** 存储使用率 (0.0-1.0) */
    val storageUsage: Float = 0f,
    
    /** 电池电量 (0-100)，可能为null（台式机等） */
    val batteryLevel: Int? = null,
    
    /** 网络上传速度 (KB/s) */
    val networkUpload: Float = 0f,
    
    /** 网络下载速度 (KB/s) */
    val networkDownload: Float = 0f,
    
    /** GPU使用率 (0.0-1.0) */
    val gpuUsage: Float = 0f,
    
    /** 系统温度 (摄氏度) */
    val temperature: Float = 0f
)
