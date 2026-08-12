package com.skybridge.compass.core.utils

/**
 * 应用常量定义
 */
object Constants {
    
    // 网络配置
    object Network {
        const val DEFAULT_PORT = 8080
        const val WEBSOCKET_PORT = 8081
        const val DISCOVERY_PORT = 8082
        const val FILE_TRANSFER_PORT = 8083
        
        const val CONNECTION_TIMEOUT = 30_000L // 30 seconds
        const val READ_TIMEOUT = 60_000L // 60 seconds
        const val WRITE_TIMEOUT = 60_000L // 60 seconds
        
        const val HEARTBEAT_INTERVAL = 10_000L // 10 seconds
        const val RECONNECT_DELAY = 5_000L // 5 seconds
        const val MAX_RECONNECT_ATTEMPTS = 3
        
        const val BUFFER_SIZE = 8192 // 8KB
        const val MAX_MESSAGE_SIZE = 1024 * 1024 // 1MB
    }
    
    // 设备发现配置
    object Discovery {
        const val BROADCAST_INTERVAL = 5_000L // 5 seconds
        const val DEVICE_TIMEOUT = 30_000L // 30 seconds
        const val SCAN_DURATION = 10_000L // 10 seconds
        
        const val MULTICAST_ADDRESS = "224.0.0.1"
        const val BROADCAST_MESSAGE = "SKYBRIDGE_DISCOVERY"
        const val RESPONSE_MESSAGE = "SKYBRIDGE_RESPONSE"
    }
    
    // 屏幕镜像配置
    object ScreenMirroring {
        const val DEFAULT_QUALITY = 80 // JPEG quality 0-100
        const val DEFAULT_FPS = 30
        const val MAX_FPS = 60
        const val MIN_FPS = 10
        
        const val DEFAULT_WIDTH = 1920
        const val DEFAULT_HEIGHT = 1080
        const val MIN_WIDTH = 640
        const val MIN_HEIGHT = 480
        
        const val FRAME_BUFFER_SIZE = 10
        const val COMPRESSION_QUALITY = 85
    }
    
    // 文件传输配置
    object FileTransfer {
        const val CHUNK_SIZE = 64 * 1024 // 64KB
        const val MAX_FILE_SIZE = 100 * 1024 * 1024L // 100MB
        const val TRANSFER_TIMEOUT = 300_000L // 5 minutes
        
        const val PROGRESS_UPDATE_INTERVAL = 1000L // 1 second
        const val RETRY_ATTEMPTS = 3
        const val RETRY_DELAY = 2000L // 2 seconds
    }
    
    // 远程控制配置
    object RemoteControl {
        const val INPUT_BUFFER_SIZE = 100
        const val GESTURE_TIMEOUT = 500L // 500ms
        const val DOUBLE_TAP_TIMEOUT = 300L // 300ms
        const val LONG_PRESS_TIMEOUT = 1000L // 1 second
        
        const val MOUSE_SENSITIVITY = 1.0f
        const val SCROLL_SENSITIVITY = 1.0f
    }
    
    // 数据库配置
    object Database {
        const val CLEANUP_INTERVAL = 24 * 60 * 60 * 1000L // 24 hours
        const val DEVICE_RETENTION_DAYS = 30
        const val CONNECTION_RETENTION_DAYS = 7
        const val LOG_RETENTION_DAYS = 3
    }
    
    // 权限配置
    object Permissions {
        val REQUIRED_PERMISSIONS = arrayOf(
            android.Manifest.permission.INTERNET,
            android.Manifest.permission.ACCESS_NETWORK_STATE,
            android.Manifest.permission.ACCESS_WIFI_STATE,
            android.Manifest.permission.CHANGE_WIFI_STATE,
            android.Manifest.permission.ACCESS_FINE_LOCATION,
            android.Manifest.permission.BLUETOOTH_SCAN,
            android.Manifest.permission.BLUETOOTH_ADVERTISE,
            android.Manifest.permission.BLUETOOTH_CONNECT,
            android.Manifest.permission.NEARBY_WIFI_DEVICES,
            android.Manifest.permission.POST_NOTIFICATIONS
        )
        
        val OPTIONAL_PERMISSIONS = emptyArray<String>()
    }
    
    // 通知配置
    object Notifications {
        const val CHANNEL_ID_GENERAL = "skybridge_general"
        const val CHANNEL_ID_CONNECTION = "skybridge_connection"
        const val CHANNEL_ID_FILE_TRANSFER = "skybridge_file_transfer"
        const val CHANNEL_ID_SCREEN_MIRRORING = "skybridge_screen_mirroring"
        
        const val NOTIFICATION_ID_CONNECTION = 1001
        const val NOTIFICATION_ID_FILE_TRANSFER = 1002
        const val NOTIFICATION_ID_SCREEN_MIRRORING = 1003
    }
    
    // 错误代码
    object ErrorCodes {
        const val NETWORK_ERROR = 1001
        const val CONNECTION_FAILED = 1002
        const val DEVICE_NOT_FOUND = 1003
        const val PERMISSION_DENIED = 1004
        const val FILE_NOT_FOUND = 1005
        const val TRANSFER_FAILED = 1006
        const val INVALID_DATA = 1007
        const val TIMEOUT = 1008
        const val UNKNOWN_ERROR = 9999
    }
    
    // 日志标签
    object LogTags {
        const val NETWORK = "SkyBridge_Network"
        const val DISCOVERY = "SkyBridge_Discovery"
        const val CONNECTION = "SkyBridge_Connection"
        const val SCREEN_MIRRORING = "SkyBridge_ScreenMirroring"
        const val FILE_TRANSFER = "SkyBridge_FileTransfer"
        const val REMOTE_CONTROL = "SkyBridge_RemoteControl"
        const val DATABASE = "SkyBridge_Database"
        const val UI = "SkyBridge_UI"
    }
}
