package com.yunqiao.sinan.node6.model

/**
 * Node 6 状态枚举
 */
enum class Node6Status {
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
