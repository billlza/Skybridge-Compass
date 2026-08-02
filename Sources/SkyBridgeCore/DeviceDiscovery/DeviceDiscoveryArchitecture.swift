// DEDUPLICATION TARGET — not inherently macOS-only.
//
// macOS 侧的发现/连接编排实现。iOS 目前有自己的一份（DeviceDiscoveryManager (iOS)），阶段 0 只让
// SkyBridgeCore 能为 iOS 编译，不在同一二进制里立起第二套实现。采用 iOS 版本是
// 阶段 3 的逐类型迁移工作，记录在 Docs/background-wake-capability-ledger.md。
#if os(macOS)
import Foundation
import OSLog

// MARK: - SkyBridge 设备发现架构说明
// ==========================================
//
// 🏗️ 架构概览
// ==========================================
//
// 设备发现子系统采用分层架构，各组件职责明确：
//
// ┌─────────────────────────────────────────────────────────────────┐
// │ UI Layer │
// │ EnhancedDeviceDiscoveryView / DeviceListView / DashboardView │
// └─────────────────────────────────────────────────────────────────┘
// │
// ▼
// ┌─────────────────────────────────────────────────────────────────┐
// │ Service Layer (入口点) │
// │ DeviceDiscoveryService │
// │ • 单例模式，UI层主要入口 │
// │ • 协调多个子管理器 │
// │ • 提供 Combine 发布者给 UI 绑定 │
// └─────────────────────────────────────────────────────────────────┘
// │
// ▼
// ┌─────────────────────────────────────────────────────────────────┐
// │ Unified Manager Layer │
// │ UnifiedDeviceDiscoveryManager │
// │ • 统一设备模型（UnifiedDevice） │
// │ • 设备去重和合并 │
// │ • 扫描范围模式控制 │
// └─────────────────────────────────────────────────────────────────┘
// │
// ┌──────────────────┼──────────────────┐
// │ │ │
// ▼ ▼ ▼
// ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
// │ DeviceDiscovery │ │ USBDeviceDisc- │ │ iCloudDevice- │
// │ ManagerOptimized│ │ overyManager │ │ DiscoveryManager│
// │ • 网络设备 │ │ • USB设备 │ │ • iCloud设备 │
// │ • Bonjour/mDNS │ │ • IOKit │ │ • CloudKit │
// │ • SSDP │ │ • 热插拔监听 │ │ • 跨网络发现 │
// └─────────────────┘ └─────────────────┘ └─────────────────┘
// │ │ │
// ▼ ▼ ▼
// ┌─────────────────────────────────────────────────────────────────┐
// │ Utility Layer (工具) │
// │ • DeviceNameResolver - DNS 名称解析 │
// │ • DeviceClassifier - 设备类型分类 │
// │ • DeviceTypeDetector - 设备类型检测 │
// │ • IdentityResolver - 设备身份解析 │
// │ • NetworkFingerprinting - 网络指纹采集 │
// │ • SSDPDiscovery - SSDP 协议实现 │
// │ • WiFiAwareDiscovery - Wi-Fi Aware 发现 │
// │ • DiscoveryOrchestrator - 发现任务编排 │
// └─────────────────────────────────────────────────────────────────┘
//
// ==========================================
// 📌 使用指南
// ==========================================
//
// 1. UI 层推荐入口：
// - DeviceDiscoveryService.shared（单例，适合大多数场景）
// - 支持 @Published 属性，直接绑定 SwiftUI
//
// 2. 高级场景：
// - UnifiedDeviceDiscoveryManager：需要统一设备模型和去重
// - DeviceDiscoveryManagerOptimized：仅需网络设备扫描
// - USBDeviceDiscoveryManager：仅需 USB 设备
//
// 3. 已弃用：
// - DeviceDiscoveryManager：基础实现，建议使用 Optimized 版本
// - EnhancedDeviceDiscovery（Models/DeviceTypes.swift）：轻量包装，建议直接用 Service
//
// ==========================================
// ⚠️ 注意事项
// ==========================================
//
// 1. 所有管理器都标记 @MainActor，UI 操作安全
// 2. 长时间运行的扫描任务使用 .detached + TaskGroup
// 3. 避免使用 Thread.sleep 和 DispatchSemaphore.wait（已重构移除）
// 4. 设备身份验证需结合 P2PSecurityManager
//
// ==========================================

/// 设备发现架构帮助器
///
/// 提供设备发现子系统的统一入口和诊断工具
@MainActor
public struct DeviceDiscoveryArchitecture {
    
    private static let logger = Logger(
        subsystem: "com.skybridge.discovery",
        category: "Architecture"
    )
    
 // MARK: - 推荐入口
    
 /// 获取推荐的设备发现服务入口
 ///
 /// 使用示例：
 /// ```swift
 /// let service = await DeviceDiscoveryArchitecture.recommendedService
 /// await service.startDiscovery()
 /// ```
    @available(macOS 14.0, *)
    public static var recommendedService: DeviceDiscoveryService {
        return DeviceDiscoveryService.shared
    }
    
 /// 获取统一设备发现管理器（需要 UnifiedDevice 模型时使用）
    public static var unifiedManager: UnifiedDeviceDiscoveryManager {
        return UnifiedDeviceDiscoveryManager()
    }
    
 // MARK: - 诊断工具
    
 /// 打印当前设备发现子系统状态
    @available(macOS 14.0, *)
    public static func printDiagnostics() {
        let service = DeviceDiscoveryService.shared
        
        logger.info("📊 设备发现子系统诊断")
        logger.info("  • 扫描状态: \(service.isScanning ? "扫描中" : "空闲")")
        logger.info("  • 发现设备数: \(service.discoveredDevices.count)")
        
 // 按连接类型统计
        let wifiCount = service.discoveredDevices.filter { $0.connectionTypes.contains(.wifi) }.count
        let usbCount = service.discoveredDevices.filter { $0.connectionTypes.contains(.usb) }.count
        let ethernetCount = service.discoveredDevices.filter { $0.connectionTypes.contains(.ethernet) }.count
        let bluetoothCount = service.discoveredDevices.filter { $0.connectionTypes.contains(.bluetooth) }.count
        
        logger.info("  • Wi-Fi 设备: \(wifiCount)")
        logger.info("  • USB 设备: \(usbCount)")
        logger.info("  • 以太网设备: \(ethernetCount)")
        logger.info("  • 蓝牙设备: \(bluetoothCount)")
    }
    
 /// 获取架构版本信息
    public static var version: String {
        return "2.0.0 (Swift 6.2.1 / macOS 14.0+)"
    }
    
 /// 获取组件清单
    public static var componentManifest: [String: String] {
        return [
            "DeviceDiscoveryService": "UI 层主入口，单例模式",
            "UnifiedDeviceDiscoveryManager": "统一设备模型和去重",
            "DeviceDiscoveryManagerOptimized": "网络设备扫描（Bonjour/SSDP）",
            "USBDeviceDiscoveryManager": "USB 设备发现（IOKit）",
            "iCloudDeviceDiscoveryManager": "iCloud 跨网络设备发现",
            "DeviceNameResolver": "DNS 名称解析",
            "DeviceClassifier": "设备类型分类",
            "IdentityResolver": "设备身份解析",
            "DiscoveryOrchestrator": "发现任务编排"
        ]
    }
}

// MARK: - 组件职责枚举

/// 设备发现组件职责
public enum DeviceDiscoveryComponent: String, CaseIterable, Sendable {
    
    case service = "DeviceDiscoveryService"
    case unified = "UnifiedDeviceDiscoveryManager"
    case optimized = "DeviceDiscoveryManagerOptimized"
    case basic = "DeviceDiscoveryManager"
    case usb = "USBDeviceDiscoveryManager"
    case icloud = "iCloudDeviceDiscoveryManager"
    case nameResolver = "DeviceNameResolver"
    case classifier = "DeviceClassifier"
    case identity = "IdentityResolver"
    case orchestrator = "DiscoveryOrchestrator"
    
 /// 组件职责描述
    public var responsibility: String {
        switch self {
        case .service:
            return "UI 层主入口，单例模式，协调所有子管理器，提供 Combine 发布者"
        case .unified:
            return "统一设备模型（UnifiedDevice），设备去重合并，扫描范围控制"
        case .optimized:
            return "网络设备扫描，Bonjour/mDNS/SSDP，Apple Silicon 优化"
        case .basic:
            return "⚠️ 已弃用，请使用 optimized 版本"
        case .usb:
            return "USB 设备发现，IOKit 集成，热插拔监听"
        case .icloud:
            return "iCloud 跨网络设备发现，CloudKit 同步"
        case .nameResolver:
            return "DNS 名称解析，PTR 记录查询，异步解析"
        case .classifier:
            return "设备类型分类，基于服务/端口/特征判断"
        case .identity:
            return "设备身份解析，公钥指纹/MAC/UUID 匹配"
        case .orchestrator:
            return "发现任务编排，并发控制，结果聚合"
        }
    }
    
 /// 是否为推荐使用的组件
    public var isRecommended: Bool {
        switch self {
        case .service, .unified, .optimized, .usb, .icloud:
            return true
        case .basic:
            return false
        default:
            return true
        }
    }
    
 /// 所需的最低 macOS 版本
    public var minimumMacOSVersion: String {
        switch self {
        case .service, .optimized:
            return "macOS 14.0"
        case .unified:
            return "macOS 14.0"
        case .icloud:
            return "macOS 13.0"
        default:
            return "macOS 12.0"
        }
    }
}

#endif
