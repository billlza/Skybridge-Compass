import Foundation
#if canImport(AppKit)
import AppKit
#endif

public struct OperatorDesktopRequest: Sendable {
    public enum Action: String, Sendable { case devices, start, status, stop }
    public let action: Action
    public let reference: String?

    public init(action: Action, params: CrossnetControlParams) throws {
        self.action = action
        let key = action == .start ? "device_ref" : "session_ref"
        let value = params.string(key)
        guard (action != .start && action != .stop) || value != nil,
              value == nil || value.flatMap(UUID.init(uuidString:)) != nil else {
            throw CrossnetControlFailure.malformedRequest("desktop operation requires its exact UUID reference")
        }
        guard !params.contains(key) || value != nil else {
            throw CrossnetControlFailure.malformedRequest("desktop reference must be a UUID string")
        }
        reference = value.flatMap(UUID.init(uuidString:))?.uuidString
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
