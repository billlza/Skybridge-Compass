package com.yunqiao.sinan.node6.model

/**
 * 远程连接状态枚举
 */
enum class RemoteConnectionStatus {
    /** 断开连接 */
    DISCONNECTED,
    
    /** 连接中 */
    CONNECTING,
    
    /** 已连接 */
    CONNECTED,
    
    /** 流媒体传输中 */
    STREAMING,
    
    /** 连接错误 */
    ERROR,
    
    /** 重连中 */
    RECONNECTING
}
