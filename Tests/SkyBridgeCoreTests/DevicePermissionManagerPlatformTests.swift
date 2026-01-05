//
// DevicePermissionManagerPlatformTests.swift
// SkyBridgeCoreTests
//
// DevicePermissionManager 平台权限扩展测试
// 测试屏幕录制和辅助功能权限检查
//
// Requirements: 6.1, 6.2, 6.3, 6.4
//

import Testing
import Foundation
@testable import SkyBridgeCore

// MARK: - Permission Type Tests

@Suite("Platform Permission Type Tests")
struct PlatformPermissionTypeTests {
    
    @Test("SBPermissionType 应有正确的 rawValue")
    func testPermissionTypeRawValues() {
        #expect(SBPermissionType.screenRecording.rawValue == "screen_recording")
        #expect(SBPermissionType.accessibility.rawValue == "accessibility")
        #expect(SBPermissionType.localNetwork.rawValue == "local_network")
        #expect(SBPermissionType.camera.rawValue == "camera")
        #expect(SBPermissionType.microphone.rawValue == "microphone")
    }
    
    @Test("SBPermissionStatus 应有正确的 rawValue")
    func testPermissionStatusRawValues() {
        #expect(SBPermissionStatus.notDetermined.rawValue == "not_determined")
        #expect(SBPermissionStatus.authorized.rawValue == "authorized")
        #expect(SBPermissionStatus.denied.rawValue == "denied")
        #expect(SBPermissionStatus.restricted.rawValue == "restricted")
    }
}

// MARK: - Permission Monitor Tests

@Suite("Platform Permission Monitor Tests")
struct PlatformPermissionMonitorTests {
    
    @Test("PlatformPermissionMonitor 应正确初始化")
    @MainActor
    func testMonitorInitialization() {
        if #available(macOS 14.0, *) {
            let monitor = PlatformPermissionMonitor()
            #expect(monitor.isMonitoring == false)
            #expect(monitor.screenRecordingStatus == .notDetermined)
            #expect(monitor.accessibilityStatus == .notDetermined)
        }
    }
    
    @Test("PlatformPermissionMonitor 应正确启动和停止监控")
    @MainActor
    func testMonitorStartStop() async {
        if #available(macOS 14.0, *) {
            let monitor = PlatformPermissionMonitor(checkInterval: 1.0)
            
 // 启动监控
            monitor.startMonitoring()
            #expect(monitor.isMonitoring == true)
            
 // 等待一次检查
            try? await Task.sleep(nanoseconds: 100_000_000)
            
 // 停止监控
            monitor.stopMonitoring()
            #expect(monitor.isMonitoring == false)
        }
    }
    
    @Test("PlatformPermissionMonitor 重复启动应安全")
    @MainActor
    func testMonitorDoubleStart() {
        if #available(macOS 14.0, *) {
            let monitor = PlatformPermissionMonitor()
            
            monitor.startMonitoring()
            monitor.startMonitoring()  // 重复启动应该安全
            
            #expect(monitor.isMonitoring == true)
            
            monitor.stopMonitoring()
        }
    }
}

// MARK: - Notification Name Tests

@Suite("Permission Notification Tests")
struct PermissionNotificationTests {
    
    @Test("权限通知名称应正确定义")
    func testNotificationNames() {
        #expect(Notification.Name.screenRecordingPermissionDidChange.rawValue == "screenRecordingPermissionDidChange")
        #expect(Notification.Name.accessibilityPermissionDidChange.rawValue == "accessibilityPermissionDidChange")
        #expect(Notification.Name.platformPermissionDidChange.rawValue == "platformPermissionDidChange")
    }
}

// MARK: - DevicePermissionManager Extension Tests

@Suite("DevicePermissionManager Platform Extension Tests")
struct DevicePermissionManagerPlatformExtensionTests {
    
    @Test("辅助功能权限检查应返回有效状态")
    @MainActor
    func testAccessibilityPermissionCheck() {
        if #available(macOS 14.0, *) {
            let manager = DevicePermissionManager()
            let status = manager.checkAccessibilityPermission()
            
 // 状态应该是 authorized 或 denied
            #expect(status == .authorized || status == .denied)
        }
    }
    
    @Test("平台权限检查应返回所有权限状态")
    @MainActor
    func testPlatformPermissionsCheck() async {
        if #available(macOS 14.0, *) {
            let manager = DevicePermissionManager()
            let permissions = await manager.checkPlatformPermissions()
            
 // 应该包含所有平台权限类型
            #expect(permissions[.screenRecording] != nil)
            #expect(permissions[.accessibility] != nil)
            #expect(permissions[.localNetwork] != nil)
            
 // 本地网络权限应始终授权
            #expect(permissions[.localNetwork] == .authorized)
        }
    }
}
