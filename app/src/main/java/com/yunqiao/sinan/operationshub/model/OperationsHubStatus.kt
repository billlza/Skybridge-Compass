package com.yunqiao.sinan.operationshub.model

/**
 * 运营枢纽状态枚举
 */
enum class OperationsHubStatus {
    /** 空闲状态 */
    IDLE,
    
    /** 初始化中 */
    INITIALIZING,
    
    /** 就绪状态 */
    READY,
    
    /** 忙碌状态 */
    BUSY,
    
    /** 错误状态 */
    ERROR
}
