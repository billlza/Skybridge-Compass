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
import SkyBridgeCore

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

    private func t(_ key: String) -> String {
        LocalizationManager.shared.localizedString(key)
    }

    private func tf(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: LocalizationManager.shared.locale, arguments: args)
    }
    
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
            content.title = t("notifications.fileTransfer.completed")
            content.body = tf("notifications.fileTransfer.completed.body", fileName)
            content.sound = .default
            content.categoryIdentifier = "TRANSFER_COMPLETE"
        } else {
            content.title = t("notifications.fileTransfer.failed")
            content.body = tf("notifications.fileTransfer.failed.body", fileName)
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
        content.title = t("notifications.deviceDiscovered.title")
        content.body = tf("notifications.deviceDiscovered.body", deviceName)
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
                    title: t("notifications.action.showInFinder"),
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
                    title: t("notifications.action.retry"),
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
                    title: t("dashboard.action.connect"),
                    options: .foreground
                )
            ],
            intentIdentifiers: [],
            options: []
        )

        let remoteDesktopSessionCategory = UNNotificationCategory(
            identifier: RemoteDesktopSessionNotificationService.categoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        
        notificationCenter.setNotificationCategories([
            transferCompleteCategory,
            transferFailedCategory,
            deviceDiscoveredCategory,
            remoteDesktopSessionCategory
        ])
    }
}
