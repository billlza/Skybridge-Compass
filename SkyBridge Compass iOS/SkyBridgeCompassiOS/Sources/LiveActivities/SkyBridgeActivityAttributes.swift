//
// SkyBridgeActivityAttributes.swift
// SkyBridge Compass iOS
//
// Shared Live Activity attributes (compiled into BOTH app target and widget extension)
//

import Foundation
import ActivityKit

/// 灵动岛活动属性（共享）
///
/// IMPORTANT:
/// - This file must be included in both the iOS app target and the Widget extension target.
/// - Do NOT define these types only inside the widget target; the app needs them to update the activity.
@available(iOS 16.2, *)
	public struct SkyBridgeActivityAttributes: ActivityAttributes {

	    /// 动态内容（可更新）
	    public struct ContentState: Codable, Hashable, Sendable {
        // 连接状态
        public var isConnected: Bool
        public var connectedDeviceName: String?
        public var cryptoSuite: String?  // e.g., "ML-KEM-768", "X25519"

        // 传输状态
        public var isTransferring: Bool
        public var transferFileName: String?
        public var transferProgress: Double  // 0.0 - 1.0
        public var transferDirection: TransferDirection
        public var transferSpeed: String?  // e.g., "12.5 MB/s"

        // 天气状态（未连接时显示）
        public var weatherCondition: String  // SF Symbol iconName
        public var temperature: Int
        public var weatherDescription: String

        public init(
            isConnected: Bool = false,
            connectedDeviceName: String? = nil,
            cryptoSuite: String? = nil,
            isTransferring: Bool = false,
            transferFileName: String? = nil,
            transferProgress: Double = 0,
            transferDirection: TransferDirection = .none,
            transferSpeed: String? = nil,
            weatherCondition: String = "sun.max.fill",
            temperature: Int = 20,
            weatherDescription: String = "晴朗"
        ) {
            self.isConnected = isConnected
            self.connectedDeviceName = connectedDeviceName
            self.cryptoSuite = cryptoSuite
            self.isTransferring = isTransferring
            self.transferFileName = transferFileName
            self.transferProgress = transferProgress
            self.transferDirection = transferDirection
            self.transferSpeed = transferSpeed
            self.weatherCondition = weatherCondition
            self.temperature = temperature
            self.weatherDescription = weatherDescription
        }
    }

	    public enum TransferDirection: String, Codable, Hashable, Sendable {
        case none
        case upload
        case download

        public var iconName: String {
            switch self {
            case .none: return "arrow.left.arrow.right"
            case .upload: return "arrow.up.circle.fill"
            case .download: return "arrow.down.circle.fill"
            }
        }
    }

    // 固定属性
    public var appName: String = "SkyBridge"

    public init() {}
}

