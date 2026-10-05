import Foundation
import Network
#if canImport(AppKit)
import AppKit
#endif

public struct OperatorDesktopRequest: Sendable {
    public enum Action: String, Sendable { case devices, start, startAt = "start_at", status, stop }
    public let action: Action
    public let reference: String?
    public let endpoint: OperatorDesktopEndpoint?

    public init(action: Action, params: CrossnetControlParams) throws {
        self.action = action
        let starts = action == .start || action == .startAt
        let key = starts ? "device_ref" : "session_ref"
        let value = params.string(key)
        guard (!starts && action != .stop) || value != nil,
              value == nil || value.flatMap(UUID.init(uuidString:)) != nil else {
            throw CrossnetControlFailure.malformedRequest("desktop operation requires its exact UUID reference")
        }
        guard !params.contains(key) || value != nil else {
            throw CrossnetControlFailure.malformedRequest("desktop reference must be a UUID string")
        }
        reference = value.flatMap(UUID.init(uuidString:))?.uuidString
        if action == .startAt || params.contains("host") || params.contains("port") {
            guard action == .startAt, let host = params.string("host"), let port = params.int("port") else {
                throw CrossnetControlFailure.malformedRequest("desktop start requires both host and port")
            }
            endpoint = try OperatorDesktopEndpoint(host: host, port: port)
        } else { endpoint = nil }
    }
}

/// A user-supplied route to an already paired host. It never creates trust or
/// counts as a reachable listener, authenticated session, or presented frame.
public struct OperatorDesktopEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: Int) throws {
        guard let address = IPv4Address(host), let port = UInt16(exactly: port), port > 0 else {
            throw CrossnetControlFailure.malformedRequest("desktop endpoint requires a unicast IPv4 address and port 1...65535")
        }
        let bytes = Array(address.rawValue)
        guard bytes.count == 4, bytes[0] != 0, bytes[0] != 127, bytes[0] < 224,
              bytes.map(String.init).joined(separator: ".") == host else {
            throw CrossnetControlFailure.malformedRequest("desktop endpoint must be a canonical unicast IPv4 address")
        }
        self.host = host; self.port = port
    }
}

public enum OperatorDesktopRoute {
    @MainActor
    public static func directTarget(_ device: DiscoveredDevice, endpoint: OperatorDesktopEndpoint) async throws -> DiscoveredDevice {
        guard let deviceID = device.deviceId, UUID(uuidString: deviceID) != nil else {
            throw CrossnetControlFailure.sessionMutationRejected("desktop_direct_requires_trusted_host_identity")
        }
        let fingerprints = await DefaultHandshakeTrustProvider().currentPathTrustedFingerprints(for: deviceID)
        return try directTarget(device, endpoint: endpoint, trustedFingerprints: fingerprints)
    }

    /// Keeps the discovery identity while replacing only the selected route.
    /// The normal remote-control handshake still authenticates the listener.
    static func directTarget(_ device: DiscoveredDevice, endpoint: OperatorDesktopEndpoint,
                                    trustedFingerprints: Set<String>) throws -> DiscoveredDevice {
        guard !device.isLocalDevice, let deviceID = device.deviceId, UUID(uuidString: deviceID) != nil,
              let fingerprint = device.pubKeyFP?.lowercased(), fingerprint.count == 64,
              trustedFingerprints.contains(fingerprint),
              ["macos", "windows", "linux"].contains(device.platformName?.lowercased() ?? "") else {
            throw CrossnetControlFailure.sessionMutationRejected("desktop_direct_requires_trusted_host_identity")
        }
        return DiscoveredDevice(
            id: device.id, name: device.name, ipv4: endpoint.host, ipv6: nil,
            platformName: device.platformName, osVersion: device.osVersion,
            modelName: device.modelName, chip: device.chip,
            services: [], portMap: [BonjourInteropContract.remoteControlServiceType: Int(endpoint.port)],
            remoteVideoFormats: device.remoteVideoFormats, connectionTypes: device.connectionTypes,
            uniqueIdentifier: device.uniqueIdentifier, routeIdentifiers: [], source: device.source,
            deviceId: deviceID, pubKeyFP: fingerprint, macSet: device.macSet
        )
    }
}

public struct OperatorDesktopDevice: Codable, Sendable {
    public let device_ref: String
    public let name: String
    public let platform: String?
    public let available: Bool
    public let reason: String?

    public init(deviceRef: String, name: String, platform: String?, available: Bool, reason: String?) {
        device_ref = deviceRef; self.name = name; self.platform = platform
        self.available = available; self.reason = reason
    }
}

public struct OperatorDesktopSession: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case connecting, waiting_frame, ready, stopping, closed, failed }
    public let session_ref: String
    public let device_ref: String
    public let name: String
    public let phase: Phase
    public let window_visible: Bool
    public let frame_presented: Bool
    public let input_authorized: Bool
    public let input_ready: Bool
    public let error_code: String?

    public init(sessionRef: String, deviceRef: String, name: String, phase: Phase,
                windowVisible: Bool, framePresented: Bool, inputAuthorized: Bool, inputReady: Bool, errorCode: String?) {
        session_ref = sessionRef; device_ref = deviceRef; self.name = name; self.phase = phase
        window_visible = windowVisible; frame_presented = framePresented
        input_authorized = inputAuthorized; input_ready = inputReady; error_code = errorCode
    }
}

public struct OperatorDesktopResult: Codable, Sendable {
    public let runtime_target: String
    public let operation: String
    public let devices: [OperatorDesktopDevice]
    public let sessions: [OperatorDesktopSession]

    public init(operation: String, devices: [OperatorDesktopDevice] = [], sessions: [OperatorDesktopSession] = []) {
        runtime_target = "mac_app_runtime"
        self.operation = operation; self.devices = devices; self.sessions = sessions
    }
}

/// The app scene registers its own open action and confirms its actual lifetime.
/// Requesting a window never counts as seeing a rendered remote frame.
@MainActor
public final class OperatorDesktopPresentation {
    public static let shared = OperatorDesktopPresentation()
    private var open: (@MainActor () -> Void)?
    public init() {}
    public func register(_ open: @escaping @MainActor () -> Void) { self.open = open }
    #if canImport(AppKit)
    private(set) weak var window: NSWindow?
    private var windowObserverID: UUID?
    public var isVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    public var canReceiveInput: Bool {
        isVisible && window?.isKeyWindow == true && NSApplication.shared.isActive
    }
    public func bindWindow(_ window: NSWindow, observerID: UUID) {
        self.window = window
        windowObserverID = observerID
    }
    public func releaseWindow(observerID: UUID) {
        guard windowObserverID == observerID else { return }
        window = nil
        windowObserverID = nil
    }
    #else
    public var isVisible: Bool { false }
    public var canReceiveInput: Bool { false }
    #endif
    public func present() throws {
        guard let open else { throw CrossnetControlFailure.sessionMutationRejected("desktop_window_unavailable") }
        open()
    }
}
