package com.yunqiao.sinan.operationshub.model

import com.yunqiao.sinan.operationshub.manager.TransferCategory

/**
 * 文件传输统计数据类
 */
data class FileTransferStatistics(
    /** 活跃任务数 */
    val activeTasks: Int = 0,
    
    /** 已完成任务数 */
    val completedTasks: Int = 0,
    
    /** 失败任务数 */
    val failedTasks: Int = 0,
    
    /** 当前传输速度 (MB/s) */
    val currentSpeed: Float = 0f,
    
    /** 平均传输速度 (MB/s) */
    val averageSpeed: Float = 0f,
    
    /** 总传输数据量 (MB) */
    val totalDataTransferred: Long = 0L,
    
    /** 传输队列中的任务数 */
    val queuedTasks: Int = 0,

    /** 任务类型分布 */
    val categoryDistribution: Map<TransferCategory, Int> = emptyMap()
)
