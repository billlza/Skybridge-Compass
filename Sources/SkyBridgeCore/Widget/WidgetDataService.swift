// MARK: - Widget Data Service
// 主应用数据写入服务 - 负责将数据写入 App Groups 共享容器
// Requirements: 5.1, 1.3

import Foundation
import CryptoKit
import WidgetKit
import SkyBridgeWidgetShared

/// Widget 数据写入服务
/// 负责将设备状态、系统指标、文件传输数据写入 App Groups 共享容器
@MainActor
public final class WidgetDataService: ObservableObject, Sendable {
    public static let shared = WidgetDataService()

 // MARK: - Dependencies

    private let fileSystem: WidgetFileSystem
    private let containerURL: URL?
    private let encoder: JSONEncoder

 // MARK: - Throttling State

    private var pendingReload: Task<Void, Never>?
    private let reloadDebounceInterval: TimeInterval = 5.0  // 5秒内合并刷新
    private var lastReloadTime: [WidgetKind: Date] = [:]  // 每个 kind 的最后刷新时间
    private let minReloadInterval: TimeInterval = 30.0  // 同一 kind 30秒内最多刷新一次

 // MARK: - Change Detection (SHA256)

    private var lastDevicesSHA256: String = ""
    private var lastMetricsSHA256: String = ""
    private var lastTransfersSHA256: String = ""

 // MARK: - Schema Version

    private var currentSchemaVersion: Int = kWidgetDataSchemaVersion

 // MARK: - Initialization

    public init(fileSystem: WidgetFileSystem = RealFileSystem()) {
        self.fileSystem = fileSystem
        self.containerURL = widgetContainerURL()

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]  // 保证 JSON 顺序稳定

        #if DEBUG
        WidgetDataLimits.loadFromEnvironment()
        #endif
    }

 // MARK: - Public API

 /// 更新设备状态数据
 /// - Parameters:
 /// - devices: 设备列表
 /// - reason: 更新原因（调试用）
    public func updateDevices(
        _ devices: [WidgetDeviceInfo],
        reason: WidgetUpdateReason = .deviceStatusChanged
    ) {
 // 写入前按 id 排序，避免顺序抖动导致误判为变更
        let sortedDevices = devices.sorted { $0.id < $1.id }

 // 截断处理
        let (truncatedDevices, truncationInfo, event) = truncateDevicesIfNeeded(sortedDevices)

        let data = WidgetDevicesData(
            devices: truncatedDevices,
            truncationInfo: truncationInfo,
            updateReason: reason
        )

 // 后台执行重 IO
        Task.detached(priority: .utility) { [weak self, encoder] in
            guard let self else { return }
            guard let jsonData = try? encoder.encode(data) else { return }
            let newSHA256 = self.sha256String(jsonData)

            await MainActor.run {
                guard newSHA256 != self.lastDevicesSHA256 else {
                    #if DEBUG
                    print("[Widget] Devices data unchanged (SHA256 match), skipping write")
                    #endif
                    return
                }
                self.lastDevicesSHA256 = newSHA256

 // 记录截断事件
                if let event {
                    #if DEBUG
                    print("[Widget] \(event.debugDescription)")
                    #endif
                }

                self.writeToContainer(jsonData, fileName: WidgetDataLimits.devicesFileName)
                self.scheduleReload(for: [.deviceStatus])
            }
        }
    }

 /// 更新系统指标数据
    public func updateMetrics(
        _ metrics: WidgetSystemMetrics,
        reason: WidgetUpdateReason = .metricsTick
    ) {
        let data = WidgetMetricsData(
            metrics: metrics,
            updateReason: reason
        )

        Task.detached(priority: .utility) { [weak self, encoder] in
            guard let self else { return }
            guard let jsonData = try? encoder.encode(data) else { return }
            let newSHA256 = self.sha256String(jsonData)

            await MainActor.run {
                guard newSHA256 != self.lastMetricsSHA256 else { return }
                self.lastMetricsSHA256 = newSHA256

                self.writeToContainer(jsonData, fileName: WidgetDataLimits.metricsFileName)
                self.scheduleReload(for: [.systemMonitor])
            }
        }
    }

 /// 更新文件传输数据
    public func updateTransfers(
        _ transfers: [WidgetTransferInfo],
        reason: WidgetUpdateReason = .transferProgress
    ) {
        let sortedTransfers = transfers.sorted { $0.id < $1.id }
        let (truncatedTransfers, truncationInfo, event) = truncateTransfersIfNeeded(sortedTransfers)

        let data = WidgetTransfersData(
            transfers: truncatedTransfers,
            truncationInfo: truncationInfo,
            updateReason: reason
        )

        Task.detached(priority: .utility) { [weak self, encoder] in
            guard let self else { return }
            guard let jsonData = try? encoder.encode(data) else { return }
            let newSHA256 = self.sha256String(jsonData)

            await MainActor.run {
                guard newSHA256 != self.lastTransfersSHA256 else { return }
                self.lastTransfersSHA256 = newSHA256

                if let event {
                    #if DEBUG
                    print("[Widget] \(event.debugDescription)")
                    #endif
                }

                self.writeToContainer(jsonData, fileName: WidgetDataLimits.transfersFileName)
                self.scheduleReload(for: [.fileTransfer])
            }
        }
    }

 /// 事件驱动刷新：关键节点触发
    public func triggerEventDrivenReload(kinds: Set<WidgetKind>) {
        scheduleReload(for: kinds)
    }

 // MARK: - Private Methods

    private func writeToContainer(_ data: Data, fileName: String) {
        guard let containerURL else {
            #if DEBUG
            print("[Widget] Container URL unavailable, skipping write")
            #endif
            return
        }

        let fileURL = containerURL.appendingPathComponent(fileName)

        do {
            try fileSystem.write(data, to: fileURL)
            #if DEBUG
            print("[Widget] Data saved to \(fileName) (\(data.count) bytes)")
            #endif
        } catch {
            #if DEBUG
            print("[Widget] Failed to save \(fileName): \(error.localizedDescription)")
            #endif
        }
    }

 /// 节流刷新：debounce + 最低刷新间隔
    private func scheduleReload(for kinds: Set<WidgetKind>) {
        pendingReload?.cancel()
        pendingReload = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(reloadDebounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }

            let kindsSnapshot = kinds
            WidgetCenter.shared.getCurrentConfigurations { [kindsSnapshot] result in
                guard case .success(let configurations) = result, !configurations.isEmpty else { return }
                let activeKinds = Set(configurations.map(\.kind))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let now = Date()
                    for kind in kindsSnapshot where activeKinds.contains(kind.rawValue) {
                        if let lastTime = self.lastReloadTime[kind],
                           now.timeIntervalSince(lastTime) < self.minReloadInterval {
                            #if DEBUG
                            print("[Widget] \(kind.rawValue) reload throttled (min interval)")
                            #endif
                            continue
                        }

                        WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue)
                        self.lastReloadTime[kind] = now
                        #if DEBUG
                        print("[Widget] Timeline reloaded: \(kind.rawValue)")
                        #endif
                    }
                }
            }
        }
    }

 // MARK: - Truncation

    private func truncateDevicesIfNeeded(
        _ devices: [WidgetDeviceInfo]
    ) -> ([WidgetDeviceInfo], TruncationInfo?, TruncationEvent?) {
        guard devices.count > WidgetDataLimits.maxDevices else {
            return (devices, nil, nil)
        }

 // 在线设备优先，离线设备按 lastSeen 降序
        let online = devices.filter { $0.isOnline }
        let offline = devices.filter { !$0.isOnline }.sorted { $0.lastSeen > $1.lastSeen }

        var result: [WidgetDeviceInfo] = []
        result.append(contentsOf: online.prefix(WidgetDataLimits.maxDevices))

        if result.count < WidgetDataLimits.maxDevices {
            result.append(contentsOf: offline.prefix(WidgetDataLimits.maxDevices - result.count))
        }

        let omitted = devices.count - result.count
        let truncationInfo = TruncationInfo(devicesOmitted: omitted, transfersOmitted: 0)
        let event = TruncationEvent(
            payloadKind: .devices,
            originalCount: devices.count,
            truncatedCount: result.count,
            omittedCount: omitted,
            originalBytes: 0  // Will be calculated later if needed
        )

        return (result, truncationInfo, event)
    }

    private func truncateTransfersIfNeeded(
        _ transfers: [WidgetTransferInfo]
    ) -> ([WidgetTransferInfo], TruncationInfo?, TruncationEvent?) {
        guard transfers.count > WidgetDataLimits.maxTransfers else {
            return (transfers, nil, nil)
        }

 // active（progress < 1.0）优先
        let active = transfers.filter { $0.isActive }
        let completed = transfers.filter { !$0.isActive }

        var result: [WidgetTransferInfo] = []
        result.append(contentsOf: active.prefix(WidgetDataLimits.maxTransfers))

        if result.count < WidgetDataLimits.maxTransfers {
            result.append(contentsOf: completed.prefix(WidgetDataLimits.maxTransfers - result.count))
        }

        let omitted = transfers.count - result.count
        let truncationInfo = TruncationInfo(devicesOmitted: 0, transfersOmitted: omitted)
        let event = TruncationEvent(
            payloadKind: .transfers,
            originalCount: transfers.count,
            truncatedCount: result.count,
            omittedCount: omitted,
            originalBytes: 0
        )

        return (result, truncationInfo, event)
    }

 // MARK: - Helpers

    nonisolated private func sha256String(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
