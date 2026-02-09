//
// DevicePermissionManager+Platform.swift
// SkyBridgeCore
//
// DevicePermissionManager 平台权限扩展
// 添加屏幕录制和辅助功能权限检查
//
// Requirements: 6.1, 6.2, 6.3, 6.4, 6.5
//

import Foundation
import ScreenCaptureKit
import AppKit
import CoreGraphics
import OSLog
import Combine

// MARK: - Platform Permission Extension

@available(macOS 14.0, *)
extension DevicePermissionManager {
    
 // MARK: - Screen Recording Permission
    
 /// 检查屏幕录制权限
 /// - Returns: 权限状态
    public func checkScreenRecordingPermission() async -> SBPermissionStatus {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return .authorized
        } catch {
            return .denied
        }
    }
    
 /// 请求屏幕录制权限
 /// 注意：macOS 不支持直接请求屏幕录制权限，需要用户手动授权
 /// - Returns: 是否已授权
    public func requestScreenRecordingPermission() async -> Bool {
        let status = await checkScreenRecordingPermission()
        if status == .authorized {
            return true
        }

        let granted = await MainActor.run { CGRequestScreenCaptureAccess() }
        if !granted {
            openScreenRecordingSettings()
        }
        return granted
    }
    
 /// 打开屏幕录制权限设置
    public func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    
 // MARK: - Accessibility Permission
    
 /// 检查辅助功能权限
 /// - Returns: 权限状态
    public func checkAccessibilityPermission() -> SBPermissionStatus {
        return AXIsProcessTrusted() ? .authorized : .denied
    }
    
 /// 请求辅助功能权限
 /// - Returns: 是否已授权
    public func requestAccessibilityPermission() -> Bool {
 // 使用字符串常量避免并发安全问题
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
 /// 打开辅助功能权限设置
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
 // MARK: - Combined Platform Permission Check
    
 /// 检查所有平台权限（屏幕录制 + 辅助功能）
 /// - Returns: 权限状态字典
    public func checkPlatformPermissions() async -> [SBPermissionType: SBPermissionStatus] {
        var results: [SBPermissionType: SBPermissionStatus] = [:]
        
 // 检查屏幕录制权限
        results[.screenRecording] = await checkScreenRecordingPermission()
        
 // 检查辅助功能权限
        results[.accessibility] = checkAccessibilityPermission()
        
 // 本地网络权限在 macOS 上始终授权
        results[.localNetwork] = .authorized
        
        return results
    }
    
 /// 请求所有平台权限
 /// - Returns: 是否所有权限都已授权
    public func requestAllPlatformPermissions() async -> Bool {
 // 请求辅助功能权限
        let accessibilityGranted = requestAccessibilityPermission()
        
 // 请求屏幕录制权限
        let screenRecordingGranted = await requestScreenRecordingPermission()
        
        return accessibilityGranted && screenRecordingGranted
    }
    
 /// 打开平台权限设置
 /// - Parameter type: 权限类型
    public func openPlatformPermissionSettings(_ type: SBPermissionType) {
        switch type {
        case .screenRecording:
            openScreenRecordingSettings()
        case .accessibility:
            openAccessibilitySettings()
        default:
            openSystemPreferences()
        }
    }
}

// MARK: - Permission Status Notification

/// 权限状态变更通知
public extension Notification.Name {
 /// 屏幕录制权限状态变更
    static let screenRecordingPermissionDidChange = Notification.Name("screenRecordingPermissionDidChange")
 /// 辅助功能权限状态变更
    static let accessibilityPermissionDidChange = Notification.Name("accessibilityPermissionDidChange")
 /// 平台权限状态变更
    static let platformPermissionDidChange = Notification.Name("platformPermissionDidChange")
}

// MARK: - Permission Monitor

/// 平台权限监控器
@available(macOS 14.0, *)
@MainActor
public final class PlatformPermissionMonitor: ObservableObject {
    
 // MARK: - Published State
    
    @Published public private(set) var screenRecordingStatus: SBPermissionStatus = .notDetermined
    @Published public private(set) var accessibilityStatus: SBPermissionStatus = .notDetermined
    @Published public private(set) var isMonitoring: Bool = false
    
 // MARK: - Private State
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "PlatformPermissionMonitor")
    private var monitorTask: Task<Void, Never>?
    private let checkInterval: TimeInterval
    
 // MARK: - Initialization
    
 /// 初始化权限监控器
 /// - Parameter checkInterval: 检查间隔（秒），默认 5 秒
    public init(checkInterval: TimeInterval = 5.0) {
        self.checkInterval = checkInterval
    }
    
    deinit {
        monitorTask?.cancel()
    }
    
 // MARK: - Public Interface
    
 /// 开始监控权限状态
    public func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        logger.info("开始监控平台权限状态")
        
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkPermissions()
                try? await Task.sleep(nanoseconds: UInt64(self?.checkInterval ?? 5.0) * 1_000_000_000)
            }
        }
    }
    
 /// 停止监控权限状态
    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        isMonitoring = false
        logger.info("停止监控平台权限状态")
    }
    
 /// 立即检查权限状态
    public func checkPermissions() async {
 // 检查屏幕录制权限
        let newScreenRecordingStatus = await checkScreenRecordingPermissionInternal()
        if newScreenRecordingStatus != screenRecordingStatus {
            let oldStatus = screenRecordingStatus
            screenRecordingStatus = newScreenRecordingStatus
            logger.info("屏幕录制权限状态变更: \(oldStatus.rawValue) -> \(newScreenRecordingStatus.rawValue)")
            NotificationCenter.default.post(name: .screenRecordingPermissionDidChange, object: newScreenRecordingStatus)
        }
        
 // 检查辅助功能权限
        let newAccessibilityStatus = checkAccessibilityPermissionInternal()
        if newAccessibilityStatus != accessibilityStatus {
            let oldStatus = accessibilityStatus
            accessibilityStatus = newAccessibilityStatus
            logger.info("辅助功能权限状态变更: \(oldStatus.rawValue) -> \(newAccessibilityStatus.rawValue)")
            NotificationCenter.default.post(name: .accessibilityPermissionDidChange, object: newAccessibilityStatus)
        }
    }
    
 // MARK: - Private Methods
    
    private func checkScreenRecordingPermissionInternal() async -> SBPermissionStatus {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return .authorized
        } catch {
            return .denied
        }
    }
    
    private nonisolated func checkAccessibilityPermissionInternal() -> SBPermissionStatus {
        return AXIsProcessTrusted() ? .authorized : .denied
    }
}
