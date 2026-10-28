#if os(macOS)
import CoreWLAN
import Foundation

/// Only value snapshots cross the CoreWLAN / UI boundary. CWInterface and
/// CWNetwork stay on the dedicated serial executor, including initialization.
struct WiFiRadioNetwork: Sendable {
    let ssid: String?
    let bssid: String?
    let channel: Int
    let band: WiFiBand
    let rssi: Int
    let security: WiFiSecurity
    let frequency: Double
}

struct WiFiRadioConnection: Sendable {
    let interfaceName: String?
    let powerOn: Bool
    let ssid: String?
    let bssid: String?
    let channel: Int
    let band: WiFiBand
    let rssi: Int
}

struct WiFiRadioScan: Sendable {
    let networks: [WiFiRadioNetwork]
    let connection: WiFiRadioConnection
}

protocol WiFiRadioAccess: Sendable {
    func scan() async throws -> WiFiRadioScan
    func connection() async throws -> WiFiRadioConnection
    func connect(ssid: String, bssid: String?, password: String?) async throws -> WiFiRadioScan
    func disconnect() async throws
}

/// Synchronous hardware operations, owned exclusively by CoreWLANClient.
/// The factory also provides a way to exercise slow/failing I/O in regression tests.
protocol WiFiRadioHardware {
    func scan() throws -> WiFiRadioScan
    func connection() throws -> WiFiRadioConnection
    func connect(ssid: String, bssid: String?, password: String?) throws -> WiFiRadioScan
    func disconnect() throws
}

actor CoreWLANClient: WiFiRadioAccess {
    static let shared = CoreWLANClient()

    // A normal actor would occupy a cooperative executor thread during a scan.
    // CoreWLAN blocks for seconds, so use a dedicated Dispatch serial executor.
    private nonisolated let queue = DispatchSerialQueue(label: "com.skybridge.corewlan", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let makeHardware: @Sendable () -> any WiFiRadioHardware
    private var hardware: (any WiFiRadioHardware)?

    init(makeHardware: @escaping @Sendable () -> any WiFiRadioHardware = { SystemWiFiRadio() }) {
        self.makeHardware = makeHardware
    }

    private func radio() -> any WiFiRadioHardware {
        if let hardware { return hardware }
        let hardware = makeHardware()
        self.hardware = hardware
        return hardware
    }

    func scan() throws -> WiFiRadioScan {
        try Task.checkCancellation()
        let result = try radio().scan()
        try Task.checkCancellation()
        return result
    }

    func connection() throws -> WiFiRadioConnection {
        try Task.checkCancellation()
        let result = try radio().connection()
        try Task.checkCancellation()
        return result
    }

    func connect(ssid: String, bssid: String?, password: String?) throws -> WiFiRadioScan {
        try Task.checkCancellation()
        let result = try radio().connect(ssid: ssid, bssid: bssid, password: password)
        try Task.checkCancellation()
        return result
    }

    func disconnect() throws {
        try Task.checkCancellation()
        try radio().disconnect()
    }
}

private enum WiFiRadioError: LocalizedError {
    case interfaceUnavailable
    case networkNotFound

    var errorDescription: String? {
        switch self {
        case .interfaceUnavailable: return "WiFi 接口不可用"
        case .networkNotFound: return "未找到目标 WiFi 网络"
        }
    }
}

private final class SystemWiFiRadio: WiFiRadioHardware {
    private let client = CWWiFiClient.shared()

    private func interface() throws -> CWInterface {
        guard let interface = client.interface() else { throw WiFiRadioError.interfaceUnavailable }
        return interface
    }

    func scan() throws -> WiFiRadioScan {
        let interface = try interface()
        let networks = try interface.scanForNetworks(withSSID: nil)
        return WiFiRadioScan(networks: networks.map(snapshot), connection: connectionSnapshot(interface))
    }

    func connection() throws -> WiFiRadioConnection {
        connectionSnapshot(try interface())
    }

    func connect(ssid: String, bssid: String?, password: String?) throws -> WiFiRadioScan {
        let interface = try interface()
        let networks = try interface.scanForNetworks(withSSID: Data(ssid.utf8))
        // Cancellation cannot interrupt an already-running system scan. Check it
        // again before the side effect, so stopping a queued auto-connect is effective.
        try Task.checkCancellation()
        guard let target = networks.first(where: { network in
            if let bssid { return network.bssid == bssid }
            return network.ssid == ssid
        }) else { throw WiFiRadioError.networkNotFound }
        try interface.associate(to: target, password: password)
        return WiFiRadioScan(networks: [snapshot(target)], connection: connectionSnapshot(interface))
    }

    func disconnect() throws {
        try interface().disassociate()
    }

    private func connectionSnapshot(_ interface: CWInterface) -> WiFiRadioConnection {
        let channel = interface.wlanChannel()
        return WiFiRadioConnection(
            interfaceName: interface.interfaceName, powerOn: interface.powerOn(),
            ssid: interface.ssid(), bssid: interface.bssid(),
            channel: channel?.channelNumber ?? 0,
            band: WiFiBand.from(channel: channel?.channelNumber ?? 0, channelBand: channel?.channelBand),
            rssi: interface.rssiValue()
        )
    }

    private func snapshot(_ network: CWNetwork) -> WiFiRadioNetwork {
        let channel = network.wlanChannel
        return WiFiRadioNetwork(
            ssid: network.ssid, bssid: network.bssid, channel: channel?.channelNumber ?? 0,
            band: WiFiBand.from(channel: channel?.channelNumber ?? 0, channelBand: channel?.channelBand),
            rssi: network.rssiValue, security: security(network),
            frequency: Double(channel?.channelBand.rawValue ?? 0)
        )
    }

    private func security(_ network: CWNetwork) -> WiFiSecurity {
        if network.supportsSecurity(.none) { return .none }
        if network.supportsSecurity(.WEP) { return .wep }
        if network.supportsSecurity(.wpaPersonal) || network.supportsSecurity(.wpaPersonalMixed) { return .wpa }
        if network.supportsSecurity(.wpa2Personal) { return .wpa2 }
        if network.supportsSecurity(.wpa3Personal) || network.supportsSecurity(.wpa3Transition) { return .wpa3 }
        if network.supportsSecurity(.wpaEnterprise) || network.supportsSecurity(.wpa2Enterprise)
            || network.supportsSecurity(.wpa3Enterprise) || network.supportsSecurity(.wpaEnterpriseMixed) { return .enterprise }
        return .unknown
    }
}
#endif
