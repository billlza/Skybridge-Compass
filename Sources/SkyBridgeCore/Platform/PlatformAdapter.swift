//
// PlatformAdapter.swift
// SkyBridgeCore
//
// 平台适配器协议 - 定义跨平台抽象接口
// 各平台（macOS/iOS/Android/Windows/Linux）实现具体功能
//
// Requirements: 10.1, 10.2, 10.3, 10.4
//

import Foundation

// MARK: - Platform Adapter Protocol

/// 平台适配器协议 - 定义跨平台抽象接口
public protocol PlatformAdapter: Sendable {
    
 // MARK: - Screen Capture
    
 /// 启动屏幕捕获
 /// - Parameter config: 屏幕捕获配置
    func startScreenCapture(config: ScreenCaptureConfig) async throws
    
 /// 停止屏幕捕获
    func stopScreenCapture() async
    
 /// 获取当前屏幕帧
 /// - Returns: 屏幕帧数据，如果未启动捕获则返回 nil
    func getScreenFrame() async -> ScreenFrame?
    
 // MARK: - Input Injection
    
 /// 注入鼠标事件
 /// - Parameter event: 远程鼠标事件
    func injectMouseEvent(_ event: SBRemoteMouseEvent) async throws
    
 /// 注入键盘事件
 /// - Parameter event: 远程键盘事件
    func injectKeyboardEvent(_ event: SBRemoteKeyboardEvent) async throws
    
 /// 注入滚动事件
 /// - Parameter event: 远程滚动事件
    func injectScrollEvent(_ event: SBRemoteScrollEvent) async throws
    
 // MARK: - Permission Management
    
 /// 检查权限状态
 /// - Parameter type: 权限类型
 /// - Returns: 权限状态
    func checkPermission(_ type: SBPermissionType) async -> SBPermissionStatus
    
 /// 请求权限
 /// - Parameter type: 权限类型
 /// - Returns: 是否授权成功
    func requestPermission(_ type: SBPermissionType) async -> Bool
    
 /// 打开权限设置页面
 /// - Parameter type: 权限类型
    func openPermissionSettings(_ type: SBPermissionType)
}

// MARK: - Screen Capture Types

/// 屏幕捕获配置
public struct ScreenCaptureConfig: Codable, Sendable, Equatable {
 /// 捕获宽度（nil 表示使用屏幕原始宽度）
    public let width: Int?
 /// 捕获高度（nil 表示使用屏幕原始高度）
    public let height: Int?
 /// 帧率
    public let frameRate: Int
 /// 像素格式
    public let pixelFormat: PixelFormat
 /// 是否显示光标
    public let showsCursor: Bool
    
    public init(
        width: Int? = nil,
        height: Int? = nil,
        frameRate: Int = 60,
        pixelFormat: PixelFormat = .bgra,
        showsCursor: Bool = true
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.pixelFormat = pixelFormat
        self.showsCursor = showsCursor
    }
    
 /// 默认配置
    public static let `default` = ScreenCaptureConfig()
}

/// 像素格式
public enum PixelFormat: String, Codable, Sendable {
    case bgra = "BGRA"
    case rgba = "RGBA"
    case nv12 = "NV12"
    case i420 = "I420"
}

/// 屏幕帧
public struct ScreenFrame: Sendable {
 /// 帧宽度
    public let width: Int
 /// 帧高度
    public let height: Int
 /// 像素格式
    public let format: PixelFormat
 /// 帧数据
    public let data: Data
 /// 时间戳
    public let timestamp: TimeInterval
 /// 是否为关键帧
    public let isKeyFrame: Bool
    
    public init(
        width: Int,
        height: Int,
        format: PixelFormat,
        data: Data,
        timestamp: TimeInterval,
        isKeyFrame: Bool
    ) {
        self.width = width
        self.height = height
        self.format = format
        self.data = data
        self.timestamp = timestamp
        self.isKeyFrame = isKeyFrame
    }
}

// MARK: - Platform Permission Types

/// 平台权限类型（跨平台协议）
public enum SBPermissionType: String, Codable, Sendable {
 /// 屏幕录制权限
    case screenRecording = "screen_recording"
 /// 辅助功能权限（用于输入注入）
    case accessibility = "accessibility"
 /// 本地网络权限
    case localNetwork = "local_network"
 /// 摄像头权限
    case camera = "camera"
 /// 麦克风权限
    case microphone = "microphone"
}

/// 平台权限状态（跨平台协议）
public enum SBPermissionStatus: String, Codable, Sendable {
 /// 未确定（用户尚未做出选择）
    case notDetermined = "not_determined"
 /// 已授权
    case authorized = "authorized"
 /// 已拒绝
    case denied = "denied"
 /// 受限（系统策略限制）
    case restricted = "restricted"
}

// MARK: - Platform Adapter Error

/// 平台适配器错误
public enum PlatformAdapterError: Error, LocalizedError, Sendable {
 /// 没有可用的显示器
    case noDisplayAvailable
 /// 权限被拒绝
    case permissionDenied(SBPermissionType)
 /// 屏幕捕获未启动
    case captureNotStarted
 /// 输入注入失败
    case inputInjectionFailed(String)
 /// 设备发现失败
    case discoveryFailed(String)
 /// 不支持的操作
    case unsupportedOperation(String)
    
    public var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "没有可用的显示器"
        case .permissionDenied(let type):
            return "权限被拒绝: \(type.rawValue)"
        case .captureNotStarted:
            return "屏幕捕获未启动"
        case .inputInjectionFailed(let reason):
            return "输入注入失败: \(reason)"
        case .discoveryFailed(let reason):
            return "设备发现失败: \(reason)"
        case .unsupportedOperation(let operation):
            return "不支持的操作: \(operation)"
        }
    }
}
