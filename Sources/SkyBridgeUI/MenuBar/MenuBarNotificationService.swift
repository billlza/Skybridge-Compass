//
// MenuBarNotificationService.swift
// SkyBridgeUI
//
// Menu Bar App - Transfer Completion Notifications
// Requirements: 4.3, 4.4
//

import Foundation
import UserNotifications
import os.log

/// 菜单栏通知服务 - 处理传输完成通知
/// Requirements: 4.3, 4.4
@available(macOS 14.0, *)
@MainActor
public final class MenuBarNotificationService {
    
 // MARK: - Singleton
    
    public static let shared = MenuBarNotificationService()
    
 // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.skybridge.ui", category: "MenuBarNotification")
    private let notificationCenter = UNUserNotificationCenter.current()
    
 // MARK: - Initialization
    
    private init() {
        setupNotificationCategories()
    }
    
 // MARK: - Public Methods
    
 /// 发送传输完成通知
 /// Requirements: 4.3
    public func sendTransferCompletedNotification(
        fileName: String,
        transferId: String,
        success: Bool
    ) {
        let content = UNMutableNotificationContent()
        
        if success {
            content.title = "传输完成"
            content.body = "\(fileName) 已成功传输"
            content.sound = .default
            content.categoryIdentifier = "TRANSFER_COMPLETE"
        } else {
            content.title = "传输失败"
            content.body = "\(fileName) 传输失败"
            content.sound = UNNotificationSound.defaultCritical
            content.categoryIdentifier = "TRANSFER_FAILED"
        }
        
        content.userInfo = [
            "transferId": transferId,
            "fileName": fileName,
            "success": success
        ]
        
        let request = UNNotificationRequest(
            identifier: "transfer-\(transferId)",
            content: content,
            trigger: nil // 立即发送
        )
        
        notificationCenter.add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("发送通知失败: \(error.localizedDescription)")
            } else {
                self?.logger.debug("通知已发送: \(fileName) - \(success ? "成功" : "失败")")
            }
        }
        
 // 同时更新菜单栏图标状态
 // Requirements: 4.4
        if !success {
            MenuBarController.shared.updateIconState(.error)
        }
    }
    
 /// 发送设备发现通知
    public func sendDeviceDiscoveredNotification(deviceName: String) {
        let content = UNMutableNotificationContent()
        content.title = "发现新设备"
        content.body = "已发现设备: \(deviceName)"
        content.sound = .default
        content.categoryIdentifier = "DEVICE_DISCOVERED"
        
        let request = UNNotificationRequest(
            identifier: "device-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("发送设备发现通知失败: \(error.localizedDescription)")
            }
        }
    }
    
 // MARK: - Private Methods
    
 /// 设置通知类别
    private func setupNotificationCategories() {
 // 传输完成类别
        let transferCompleteCategory = UNNotificationCategory(
            identifier: "TRANSFER_COMPLETE",
            actions: [
                UNNotificationAction(
                    identifier: "SHOW_FILE",
                    title: "在 Finder 中显示",
                    options: .foreground
                )
            ],
            intentIdentifiers: [],
            options: []
        )
        
 // 传输失败类别
        let transferFailedCategory = UNNotificationCategory(
            identifier: "TRANSFER_FAILED",
            actions: [
                UNNotificationAction(
                    identifier: "RETRY",
                    title: "重试",
                    options: .foreground
                )
            ],
            intentIdentifiers: [],
            options: []
        )
        
 // 设备发现类别
        let deviceDiscoveredCategory = UNNotificationCategory(
            identifier: "DEVICE_DISCOVERED",
            actions: [
                UNNotificationAction(
                    identifier: "CONNECT",
                    title: "连接",
                    options: .foreground
                )
            ],
            intentIdentifiers: [],
            options: []
        )
        
        notificationCenter.setNotificationCategories([
            transferCompleteCategory,
            transferFailedCategory,
            deviceDiscoveredCategory
        ])
    }
}
