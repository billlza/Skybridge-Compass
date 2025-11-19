import Foundation

public struct DiscoveredDevice: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let location: String
    public let medium: DeviceConnectionMedium
    public let services: Int
    public let latency: String
    public let isSecure: Bool

    public init(id: UUID = .init(), name: String, location: String, medium: DeviceConnectionMedium, services: Int, latency: String, isSecure: Bool) {
        self.id = id
        self.name = name
        self.location = location
        self.medium = medium
        self.services = services
        self.latency = latency
        self.isSecure = isSecure
    }
}

public enum DeviceConnectionMedium: String, CaseIterable, Sendable {
    case wifi = "Wi‑Fi"
    case usb = "USB"
    case ethernet = "Ethernet"
}

public extension DiscoveredDevice {
    static let mockDevices: [DiscoveredDevice] = [
        DiscoveredDevice(name: "Skybridge Studio", location: "局域网 · 上海", medium: .ethernet, services: 6, latency: "12 ms", isSecure: true),
        DiscoveredDevice(name: "M2 Ultra Lab", location: "Wi‑Fi · 杭州", medium: .wifi, services: 5, latency: "28 ms", isSecure: true),
        DiscoveredDevice(name: "Diagnostics NUC", location: "USB-C", medium: .usb, services: 3, latency: "1 ms", isSecure: false)
    ]
}
