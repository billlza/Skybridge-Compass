package com.yunqiao.sinan.node6.model

/**
 * Node 6 总体统计数据类
 */
data class Node6OverallStatistics(
    /** 系统运行时间（毫秒） */
    val uptime: Long = 0L,
    
    /** 已处理任务数 */
    val processedTasks: Long = 0L,
    
    /** 失败任务数 */
    val failedTasks: Long = 0L,
    
    /** 当前活跃连接数 */
    val activeConnections: Int = 0,
    
    /** 数据传输量（字节） */
    val totalDataTransferred: Long = 0L,
    
    /** 系统负载 (0.0-1.0) */
    val systemLoad: Float = 0f,
    
    /** 内存使用量（字节） */
    val memoryUsage: Long = 0L,
    
    /** 网络延迟（毫秒） */
    val networkLatency: Float = 0f,
    
    /** 上次更新时间 */
    val lastUpdateTime: Long = System.currentTimeMillis()
)
