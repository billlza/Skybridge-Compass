import Foundation
import WidgetKit

struct DeviceStatusStore: Sendable {
    private let suiteName = "group.com.skybridge.compass"
    private let key = "device-status"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    func persist(_ status: DeviceStatus) {
        guard let data = try? encoder.encode(status) else { return }
        defaults.set(data, forKey: key)
        WidgetCenter.shared.reloadTimelines(ofKind: "SkybridgeCompassWidget")
    }

    func latestStatus() -> DeviceStatus? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(DeviceStatus.self, from: data)
    }

    func latestSnapshot() -> DeviceStatusSnapshot {
        if let status = latestStatus() {
            return DeviceStatusSnapshot(date: status.timestamp, status: status)
        }
        return DeviceStatusSnapshot(date: .now, status: .placeholder)
    }
}
