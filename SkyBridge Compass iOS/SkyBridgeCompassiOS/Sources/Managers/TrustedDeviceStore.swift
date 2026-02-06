import Foundation
import Combine

/// 受信任设备存储（持久化）
/// - 目的：让 iOS 端的“受信任设备”不再是占位 UI，并能和握手/验证流程挂钩
@MainActor
public final class TrustedDeviceStore: ObservableObject {
    public static let shared = TrustedDeviceStore()

    public struct TrustedDevice: Codable, Identifiable, Sendable, Equatable {
        public let id: String // 建议使用 discovery TXT 的 uuid / 或配对 deviceId
        public var name: String
        public var platform: DevicePlatform
        public var ipAddress: String?
        public var addedAt: Date

        public init(id: String, name: String, platform: DevicePlatform, ipAddress: String?, addedAt: Date = Date()) {
            self.id = id
            self.name = name
            self.platform = platform
            self.ipAddress = ipAddress
            self.addedAt = addedAt
        }
    }

    @Published public private(set) var trustedDevices: [TrustedDevice] = []

    private let storageKey = "trusted_devices.v1"

    private init() {
        load()
    }

    public func isTrusted(deviceId: String) -> Bool {
        trustedDevices.contains(where: { $0.id == deviceId })
    }

    public func trust(_ device: DiscoveredDevice) {
        let id = device.id
        guard !id.isEmpty else { return }
        if let idx = trustedDevices.firstIndex(where: { $0.id == id }) {
            trustedDevices[idx].name = device.name
            trustedDevices[idx].platform = device.platform
            trustedDevices[idx].ipAddress = device.ipAddress
        } else {
            trustedDevices.append(
                TrustedDevice(
                    id: id,
                    name: device.name,
                    platform: device.platform,
                    ipAddress: device.ipAddress
                )
            )
        }
        save()
    }

    /// 合并 CloudKit 同步的可信设备（并集策略：不自动删除本地设备）
    public func mergeFromCloud(_ devices: [TrustedDevice]) {
        guard !devices.isEmpty else { return }

        var changed = false

        for remote in devices {
            guard !remote.id.isEmpty else { continue }

            if let idx = trustedDevices.firstIndex(where: { $0.id == remote.id }) {
                var current = trustedDevices[idx]

                if !remote.name.isEmpty, remote.name != current.name {
                    current.name = remote.name
                    changed = true
                }
                if remote.platform != .unknown, remote.platform != current.platform {
                    current.platform = remote.platform
                    changed = true
                }
                if let ip = remote.ipAddress, !ip.isEmpty, ip != current.ipAddress {
                    current.ipAddress = ip
                    changed = true
                }
                // addedAt：取更早的时间，保持“首次信任时间”语义
                if remote.addedAt < current.addedAt {
                    current.addedAt = remote.addedAt
                    changed = true
                }

                if changed {
                    trustedDevices[idx] = current
                }
            } else {
                trustedDevices.append(remote)
                changed = true
            }
        }

        if changed {
            save()
        }
    }

    public func untrust(deviceId: String) {
        trustedDevices.removeAll { $0.id == deviceId }
        save()
    }

    public func clearAll() {
        trustedDevices.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        trustedDevices = (try? JSONDecoder().decode([TrustedDevice].self, from: data)) ?? []
    }

    private func save() {
        let data = (try? JSONEncoder().encode(trustedDevices)) ?? Data()
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

