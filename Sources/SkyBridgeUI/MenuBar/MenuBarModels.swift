//
// MenuBarModels.swift
// SkyBridgeUI
//
// Menu Bar App - Data Models
// Requirements: 4.1, 4.4, 1.1
//

import Foundation

// MARK: - MenuBarIconState

/// 菜单栏图标状态枚举
/// Requirements: 4.1, 4.4
public enum MenuBarIconState: Sendable, Equatable {
 /// 正常状态
    case normal
 /// 传输中，带进度 (0.0 - 1.0)
    case transferring(progress: Double)
 /// 错误状态
    case error
 /// 扫描中
    case scanning
    
 /// 获取进度值（仅传输状态有效）
    public var progress: Double? {
        if case .transferring(let p) = self {
            return p
        }
        return nil
    }
    
 /// 是否为活跃状态（传输中或扫描中）
    public var isActive: Bool {
        switch self {
        case .transferring, .scanning:
            return true
        case .normal, .error:
            return false
        }
    }
}

// MARK: - MenuBarTransferItem

/// 菜单栏传输项数据模型
/// Requirements: 4.1, 4.2
public struct MenuBarTransferItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let fileName: String
    public let progress: Double
    public let speed: Double
    public let state: TransferState
    
 /// 传输状态
    public enum TransferState: Sendable, Equatable {
        case transferring
        case completed
        case failed
        case paused
    }
    
    public init(
        id: String,
        fileName: String,
        progress: Double,
        speed: Double,
        state: TransferState
    ) {
        self.id = id
        self.fileName = fileName
        self.progress = progress
        self.speed = speed
        self.state = state
    }
    
 /// 格式化速度显示
    public var formattedSpeed: String {
        if speed >= 1_000_000_000 {
            return String(format: "%.1f GB/s", speed / 1_000_000_000)
        } else if speed >= 1_000_000 {
            return String(format: "%.1f MB/s", speed / 1_000_000)
        } else if speed >= 1_000 {
            return String(format: "%.1f KB/s", speed / 1_000)
        } else {
            return String(format: "%.0f B/s", speed)
        }
    }
    
 /// 格式化进度显示
    public var formattedProgress: String {
        return String(format: "%.0f%%", progress * 100)
    }
}

// MARK: - MenuBarConfiguration

/// 菜单栏配置模型
/// Requirements: 1.1
public struct MenuBarConfiguration: Codable, Sendable, Equatable {
 /// 是否启用菜单栏图标
    public var enabled: Bool
    
 /// 弹出面板宽度
    public var popoverWidth: CGFloat
    
 /// 弹出面板高度
    public var popoverHeight: CGFloat
    
 /// 显示设备数量上限
    public var maxDevicesShown: Int
    
 /// 是否显示传输进度
    public var showTransferProgress: Bool
    
 /// 默认配置
    public static let `default` = MenuBarConfiguration(
        enabled: true,
        popoverWidth: 320,
        popoverHeight: 400,
        maxDevicesShown: 5,
        showTransferProgress: true
    )
    
    public init(
        enabled: Bool = true,
        popoverWidth: CGFloat = 320,
        popoverHeight: CGFloat = 400,
        maxDevicesShown: Int = 5,
        showTransferProgress: Bool = true
    ) {
        self.enabled = enabled
        self.popoverWidth = popoverWidth
        self.popoverHeight = popoverHeight
        self.maxDevicesShown = maxDevicesShown
        self.showTransferProgress = showTransferProgress
    }
}

// MARK: - MenuBarNotifications

/// 菜单栏相关通知
public extension Notification.Name {
 /// 请求打开主窗口
    static let menuBarOpenMainWindow = Notification.Name("com.skybridge.menubar.openMainWindow")
    
 /// 请求打开设备详情
    static let menuBarOpenDeviceDetail = Notification.Name("com.skybridge.menubar.openDeviceDetail")
    
 /// 请求打开屏幕镜像
    static let menuBarOpenScreenMirror = Notification.Name("com.skybridge.menubar.openScreenMirror")
    
 /// 请求打开文件传输
    static let menuBarOpenFileTransfer = Notification.Name("com.skybridge.menubar.openFileTransfer")
}
