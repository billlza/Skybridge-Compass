package com.yunqiao.sinan.node6.model

/**
 * 设备发现状态枚举
 */
enum class DiscoveryStatus {
    /** 空闲 */
    IDLE,
    
    /** 扫描中 */
    SCANNING,
    
    /** 扫描完成 */
    COMPLETED,
    
    /** 错误 */
    ERROR
}
