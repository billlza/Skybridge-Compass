import Foundation
import CryptoKit

public enum CrossnetControlWire {
    public static let protocolVersion = 1
    public static let maxLineByteCount = 64 * 1024
    public static let maxRequestIDLength = 128
    public static let maxMethodLength = 64

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static func decodeRequest(line: Data) throws -> CrossnetControlRequest {
        guard line.count <= maxLineByteCount else {
            throw CrossnetControlFailure.requestTooLarge
        }
        let decoded = try JSONDecoder().decode(CrossnetControlRequestEnvelope.self, from: line)
        guard decoded.v == protocolVersion else {
            throw CrossnetControlFailure.protocolVersionMismatch
        }
        guard Self.isValidRequestID(decoded.id) else {
            throw CrossnetControlFailure.malformedRequest("invalid request id")
        }
        guard Self.isValidMethod(decoded.method) else {
            throw CrossnetControlFailure.malformedRequest("invalid method")
        }
        return CrossnetControlRequest(
            id: decoded.id,
            method: decoded.method,
            params: decoded.params ?? CrossnetControlParams()
        )
    }

    public static func successData<Result: Encodable>(
        id: String,
        result: Result
    ) throws -> Data {
        try encoder.encode(CrossnetControlSuccessEnvelope(
            v: protocolVersion,
            id: id,
            result: result
        ))
    }

    /// Encodes one unsolicited stream frame, e.g. a `status` watch event.
    ///
    /// Distinct on the wire from a request/response envelope: it carries
    /// `event`/`data` instead of `id`/`ok`/`result`, so a client can tell a
    /// pushed frame from the initial response it correlated by id.
    public static func eventData<Payload: Encodable>(
        event: String,
        data: Payload
    ) throws -> Data {
        try encoder.encode(CrossnetControlEventEnvelope(
            v: protocolVersion,
            event: event,
            data: data
        ))
    }

    public static func failureData(
        id: String?,
        failure: CrossnetControlFailure
    ) -> Data {
        let envelope = CrossnetControlFailureEnvelope(
            v: protocolVersion,
            id: id,
            error: CrossnetControlErrorBody(
                code: failure.code,
                message: failure.message
            )
        )
        if let data = try? encoder.encode(envelope) {
            return data
        }
        return Data(#"{"v":1,"ok":false,"error":{"code":"internal","message":"failed to encode control error"}}"#.utf8)
    }

    public static func strictConnectionCode(_ raw: String?) throws -> String {
        guard let raw else {
            throw CrossnetControlFailure.invalidCode
        }
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              CrossnetControlConnectionCode.isSupportedLength(raw.count),
              raw.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && CrossnetControlConnectionCode.allowedScalars.contains(scalar)
              }) else {
            throw CrossnetControlFailure.invalidCode
        }
        return raw
    }

    private static func isValidRequestID(_ id: String) -> Bool {
        !id.isEmpty
            && id.count <= maxRequestIDLength
            && id.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && scalar.value >= 0x21
                    && scalar.value <= 0x7E
            }
    }

    private static func isValidMethod(_ method: String) -> Bool {
        !method.isEmpty
            && method.count <= maxMethodLength
            && method.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (
                        CharacterSet.lowercaseLetters.contains(scalar)
                        || CharacterSet.decimalDigits.contains(scalar)
                        || scalar == "."
                        || scalar == "_"
                    )
            }
    }
}

private enum CrossnetControlConnectionCode {
    private static let legacyLength = 6
    private static let preferredLength = 8
    private static let maximumLength = 16
    static let allowedScalars = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789".unicodeScalars)

    static func isSupportedLength(_ count: Int) -> Bool {
        count == legacyLength || (preferredLength...maximumLength).contains(count)
    }
}

public struct CrossnetControlRequest: Equatable, Sendable {
    public let id: String
    public let method: String
    public let params: CrossnetControlParams
}

public struct CrossnetControlParams: Equatable, Sendable, Decodable {
    private let values: [String: CrossnetControlJSONValue]

    public init(_ values: [String: CrossnetControlJSONValue] = [:]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.values = try container.decode([String: CrossnetControlJSONValue].self)
    }

    public subscript(_ key: String) -> CrossnetControlJSONValue? {
        values[key]
    }

    public func contains(_ key: String) -> Bool {
        values[key] != nil
    }

    public func string(_ key: String) -> String? {
        guard case .string(let value) = values[key] else { return nil }
        return value
    }

    public func bool(_ key: String) -> Bool? {
        guard case .bool(let value) = values[key] else { return nil }
        return value
    }

    public func int(_ key: String) -> Int? {
        guard case .int(let value) = values[key] else { return nil }
        return value
    }
}

public enum CrossnetControlJSONValue: Equatable, Sendable, Codable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported crossnet-control JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public enum CrossnetControlFailure: Error, Equatable, Sendable {
    case malformedRequest(String)
    case protocolVersionMismatch
    case methodNotFound
    case methodNotEnabled
    case watchNotSupported
    case invalidCode
    case invalidLeaseMode
    case authRequired
    case tenantRequired
    case requestTooLarge
    /// The requested setting id is not part of the operator-visible allowlist.
    case settingNotFound
    /// The setting is readable but deliberately not mutable over this channel.
    ///
    /// Carries the reason so an operator learns *why* a readable setting refuses
    /// mutation instead of seeing an indistinguishable "not allowlisted".
    case settingImmutable(String)
    /// The supplied value is outside the setting's declared type or domain.
    case settingInvalidValue
    /// The write was accepted but the runtime did not read back the requested
    /// value, so no apply is claimed.
    case settingRuntimeApplyFailed
    /// The session verb ran against the live runtime but the state read back
    /// afterwards does not support the result, so no mutation is claimed.
    ///
    /// This is the session-plane twin of ``settingRuntimeApplyFailed``: the
    /// router refuses to report a host/connect/disconnect that the app's own
    /// runtime cannot corroborate.
    case sessionRuntimeApplyFailed
    /// The app refused the session mutation for an operator-visible reason that
    /// is not an auth, tenant, or code-format problem (for example no signaling
    /// route, or an admission lease the app could not obtain).
    case sessionMutationRejected(String)
    /// The requested destination is not part of the typed navigation vocabulary.
    case navigationDestinationInvalid
    /// The navigation coordinator ran but the UI did not confirm presenting the
    /// destination (for example the dashboard window is not mounted), so no
    /// navigation is claimed.
    case navigationApplyFailed
    /// The requested device reference matches no entry in the app's current
    /// online-device snapshot.
    case deviceNotFound
    case internalError(String)

    public var code: String {
        switch self {
        case .malformedRequest:
            return "malformed_request"
        case .protocolVersionMismatch:
            return "protocol_version_mismatch"
        case .methodNotFound:
            return "method_not_found"
        case .methodNotEnabled:
            return "method_not_enabled"
        case .watchNotSupported:
            return "watch_not_supported"
        case .invalidCode:
            return "invalid_code"
        case .invalidLeaseMode:
            return "invalid_lease_mode"
        case .authRequired:
            return "auth_required"
        case .tenantRequired:
            return "tenant_required"
        case .requestTooLarge:
            return "request_too_large"
        case .settingNotFound:
            return "setting_not_found"
        case .settingImmutable:
            return "setting_immutable"
        case .settingInvalidValue:
            return "setting_invalid_value"
        case .settingRuntimeApplyFailed:
            return "setting_runtime_apply_failed"
        case .sessionRuntimeApplyFailed:
            return "session_runtime_apply_failed"
        case .sessionMutationRejected:
            return "session_mutation_rejected"
        case .navigationDestinationInvalid:
            return "navigation_destination_invalid"
        case .navigationApplyFailed:
            return "navigation_apply_failed"
        case .deviceNotFound:
            return "device_not_found"
        case .internalError:
            return "internal"
        }
    }

    public var message: String {
        switch self {
        case .malformedRequest(let detail):
            return "malformed crossnet-control request: \(Self.sanitized(detail))"
        case .protocolVersionMismatch:
            return "crossnet-control protocol version mismatch"
        case .methodNotFound:
            return "unknown crossnet-control method"
        case .methodNotEnabled:
            return "crossnet-control method is not enabled in this Mac app build"
        case .watchNotSupported:
            return "crossnet.status watch is not implemented yet"
        case .invalidCode:
            return "invalid connection code"
        case .invalidLeaseMode:
            return "invalid host lease mode"
        case .authRequired:
            return "Mac app auth session is not loaded"
        case .tenantRequired:
            return "Mac app tenant binding is unavailable"
        case .requestTooLarge:
            return "crossnet-control request line is too large"
        case .settingNotFound:
            return "unknown crossnet-control setting id"
        case .settingImmutable(let reason):
            return "crossnet-control setting is not mutable: \(Self.sanitized(reason))"
        case .settingInvalidValue:
            return "crossnet-control setting value is outside its declared domain"
        case .settingRuntimeApplyFailed:
            return "crossnet-control setting write did not read back from the Mac app runtime"
        case .sessionRuntimeApplyFailed:
            return "crossnet-control session mutation did not read back from the Mac app runtime"
        case .sessionMutationRejected(let reason):
            return "crossnet-control session mutation was refused by the Mac app: \(Self.sanitized(reason))"
        case .navigationDestinationInvalid:
            return "unknown crossnet-control navigation destination"
        case .navigationApplyFailed:
            return "crossnet-control navigation was not confirmed by the Mac app UI"
        case .deviceNotFound:
            return "unknown crossnet-control device reference"
        case .internalError(let detail):
            return "crossnet-control internal error: \(Self.sanitized(detail))"
        }
    }

    private static func sanitized(_ value: String) -> String {
        String(
            value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .prefix(160)
        )
    }
}

public enum CrossnetControlHostLeaseMode: String, Codable, Equatable, Sendable {
    case short
    case long

    public static func parse(params: CrossnetControlParams) throws -> CrossnetControlHostLeaseMode {
        guard params.contains("lease_mode") else { return .short }
        guard let raw = params.string("lease_mode") else {
            throw CrossnetControlFailure.invalidLeaseMode
        }
        return try parse(raw)
    }

    public static func parse(_ raw: String?) throws -> CrossnetControlHostLeaseMode {
        guard let raw else { return .short }
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              let mode = CrossnetControlHostLeaseMode(rawValue: raw) else {
            throw CrossnetControlFailure.invalidLeaseMode
        }
        return mode
    }
}

public struct CrossnetControlHelloResult: Codable, Equatable, Sendable {
    public let engineVersion: String
    public let proto: Int
    public let authLoaded: Bool
    public let tenantBound: Bool
    /// The mutating methods THIS app build actually implements.
    ///
    /// The CLI ships separately from the Mac app, so a newer CLI can be pointed
    /// at an older app. Without this list the CLI could only report its own
    /// compile-time expectations and would tell an operator that
    /// `crossnet.disconnect` is enabled while the installed app still answers
    /// `method_not_enabled`.
    public let enabledMutationMethods: [String]

    public init(
        engineVersion: String,
        proto: Int = CrossnetControlWire.protocolVersion,
        authLoaded: Bool,
        tenantBound: Bool,
        enabledMutationMethods: [String] = CrossnetControlMethods.enabledMutationMethods
    ) {
        self.engineVersion = engineVersion
        self.proto = proto
        self.authLoaded = authLoaded
        self.tenantBound = tenantBound
        self.enabledMutationMethods = enabledMutationMethods
    }

    private enum CodingKeys: String, CodingKey {
        case engineVersion = "engine_version"
        case proto
        case authLoaded = "auth_loaded"
        case tenantBound = "tenant_bound"
        case enabledMutationMethods = "enabled_mutation_methods"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engineVersion = try container.decode(String.self, forKey: .engineVersion)
        proto = try container.decode(Int.self, forKey: .proto)
        authLoaded = try container.decode(Bool.self, forKey: .authLoaded)
        tenantBound = try container.decode(Bool.self, forKey: .tenantBound)
        // Absent on pre-0.3.1 app builds; an empty list means "this app did not
        // say", which the CLI reports as unknown rather than as none.
        enabledMutationMethods =
            try container.decodeIfPresent([String].self, forKey: .enabledMutationMethods) ?? []
    }
}

/// The single source of truth for which mutating methods this app build serves.
///
/// ``CrossnetControlRouter`` is the only thing that can enable a method, so this
/// list lives next to it and is reported over `crossnet.hello`.
public enum CrossnetControlMethods {
    public static let enabledMutationMethods: [String] = [
        "crossnet.settings.set",
        "crossnet.host",
        "crossnet.connect",
        "crossnet.connect_device",
        "crossnet.disconnect",
        "crossnet.navigation"
    ]

    /// Mutating or mutation-adjacent methods this build still refuses.
    ///
    /// Empty since `crossnet.navigate` landed and `crossnet.status` gained a
    /// real watch stream; kept so a future gap has a declared home instead of
    /// being silently undisclosed.
    public static let disabledMutationMethods: [String] = []
}

public struct CrossnetControlHostResult: Codable, Equatable, Sendable {
    public let code: String
    public let sessionRef: String?
    public let expiresAt: String?
    public let leaseMode: CrossnetControlHostLeaseMode

    public init(
        code: String,
        sessionRef: String?,
        expiresAt: String?,
        leaseMode: CrossnetControlHostLeaseMode
    ) {
        self.code = code
        self.sessionRef = sessionRef
        self.expiresAt = expiresAt
        self.leaseMode = leaseMode
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case sessionRef = "session_ref"
        case expiresAt = "expires_at"
        case leaseMode = "lease_mode"
    }
}

/// Result of `crossnet.connect` — the session formed by redeeming a code.
///
/// `readiness` is the app's own readiness read back **after** the connect call
/// returns, never a constant. `CrossNetworkConnectionManager.connectWithCode`
/// returns once the WebRTC offer session has started, which is well before the
/// peer answers, so a hardcoded "connected" here would be a lie the operator
/// could not detect.
public struct CrossnetControlConnectResult: Codable, Equatable, Sendable {
    public let runtimeTarget: String
    public let controlEffect: String
    public let sessionRef: String
    public let remoteDeviceName: String?
    public let readiness: String
    public let connectionStatus: String

    public init(
        runtimeTarget: String = "mac_app_runtime",
        controlEffect: String = "mac_session_mutation",
        sessionRef: String,
        remoteDeviceName: String?,
        readiness: String,
        connectionStatus: String
    ) {
        self.runtimeTarget = runtimeTarget
        self.controlEffect = controlEffect
        self.sessionRef = sessionRef
        self.remoteDeviceName = remoteDeviceName
        self.readiness = readiness
        self.connectionStatus = connectionStatus
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeTarget = "runtime_target"
        case controlEffect = "control_effect"
        case sessionRef = "session_ref"
        case remoteDeviceName = "remote_device_name"
        case readiness
        case connectionStatus = "connection_status"
    }
}

/// Result of `crossnet.disconnect`.
///
/// `disconnected` reports whether a session was actually torn down, so an
/// operator can tell "I ended a session" from "there was nothing to end".
/// `sessionPresentAfter` is the post-teardown read-back the router validates.
public struct CrossnetControlDisconnectResult: Codable, Equatable, Sendable {
    public let runtimeTarget: String
    public let controlEffect: String
    public let disconnected: Bool
    public let sessionPresentBefore: Bool
    public let sessionPresentAfter: Bool
    public let connectionStatus: String

    public init(
        runtimeTarget: String = "mac_app_runtime",
        controlEffect: String = "mac_session_mutation",
        disconnected: Bool,
        sessionPresentBefore: Bool,
        sessionPresentAfter: Bool,
        connectionStatus: String
    ) {
        self.runtimeTarget = runtimeTarget
        self.controlEffect = controlEffect
        self.disconnected = disconnected
        self.sessionPresentBefore = sessionPresentBefore
        self.sessionPresentAfter = sessionPresentAfter
        self.connectionStatus = connectionStatus
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeTarget = "runtime_target"
        case controlEffect = "control_effect"
        case disconnected
        case sessionPresentBefore = "session_present_before"
        case sessionPresentAfter = "session_present_after"
        case connectionStatus = "connection_status"
    }
}

/// Fail-closed validation for the three session-plane verbs.
///
/// This is the session twin of ``CrossnetControlSettingsMutationPolicy``: the
/// router refuses to report a mutation the app's own read-back does not
/// corroborate, so a runtime that silently no-ops cannot present as success.
public enum CrossnetControlSessionMutationPolicy {
    /// Readiness strings ``CrossnetControlRuntimeProjection`` can emit.
    ///
    /// Kept as an explicit set so a runtime cannot invent a readiness the
    /// status projection would never produce.
    static let knownReadiness: Set<String> = [
        "idle",
        "transport_ready",
        "handshake_complete"
    ]

    static let knownConnectionStatus: Set<String> = [
        "idle",
        "generating",
        "waiting",
        "connecting",
        "connected",
        "failed"
    ]

    public static func validate(
        _ result: CrossnetControlHostResult,
        request leaseMode: CrossnetControlHostLeaseMode
    ) throws -> CrossnetControlHostResult {
        guard result.leaseMode == leaseMode else {
            throw CrossnetControlFailure.internalError("host_lease_mode_mismatch")
        }
        let code = result.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code == result.code else {
            throw CrossnetControlFailure.sessionRuntimeApplyFailed
        }
        // The hosting session must be identified by a redacted ref, never a raw
        // session id — the CLI prints this field verbatim.
        try requireRedactedSessionRef(result.sessionRef)
        return result
    }

    public static func validate(
        _ result: CrossnetControlConnectResult
    ) throws -> CrossnetControlConnectResult {
        try requireSessionPlane(
            runtimeTarget: result.runtimeTarget,
            controlEffect: result.controlEffect
        )
        try requireRedactedSessionRef(result.sessionRef)
        guard knownReadiness.contains(result.readiness) else {
            throw CrossnetControlFailure.internalError("connect_unknown_readiness")
        }
        guard knownConnectionStatus.contains(result.connectionStatus) else {
            throw CrossnetControlFailure.internalError("connect_unknown_connection_status")
        }
        // `handshake_complete` is the one readiness an operator would act on as
        // proof of a live secure session, so it may only be reported when the
        // app's own connection status agrees.
        if result.readiness == "handshake_complete", result.connectionStatus != "connected" {
            throw CrossnetControlFailure.sessionRuntimeApplyFailed
        }
        // A connect that left the app in `failed` is not a connect.
        if result.connectionStatus == "failed" {
            throw CrossnetControlFailure.sessionRuntimeApplyFailed
        }
        return result
    }

    public static func validate(
        _ result: CrossnetControlDisconnectResult
    ) throws -> CrossnetControlDisconnectResult {
        try requireSessionPlane(
            runtimeTarget: result.runtimeTarget,
            controlEffect: result.controlEffect
        )
        guard knownConnectionStatus.contains(result.connectionStatus) else {
            throw CrossnetControlFailure.internalError("disconnect_unknown_connection_status")
        }
        // Teardown must ALWAYS be proven by the read-back, whether or not there
        // was a session to tear down. `disconnect()` cannot fail loudly, so this
        // is the only evidence that it did anything.
        guard !result.sessionPresentAfter, result.connectionStatus == "idle" else {
            throw CrossnetControlFailure.sessionRuntimeApplyFailed
        }
        // `disconnected` reports only whether there was anything to end, so it
        // must match the observed before-state rather than being asserted by the
        // runtime. Having nothing to disconnect is a legitimate `false`, not a
        // failure — the CLI renders it as "No cross-network session to
        // disconnect".
        guard result.disconnected == result.sessionPresentBefore else {
            throw CrossnetControlFailure.internalError("disconnect_claim_mismatch")
        }
        return result
    }

    private static func requireSessionPlane(
        runtimeTarget: String,
        controlEffect: String
    ) throws {
        guard runtimeTarget == "mac_app_runtime" else {
            throw CrossnetControlFailure.internalError("session_mutation_invalid_runtime")
        }
        guard controlEffect == "mac_session_mutation" else {
            throw CrossnetControlFailure.internalError("session_mutation_invalid_effect")
        }
    }

    private static func requireRedactedSessionRef(_ sessionRef: String?) throws {
        guard let sessionRef,
              sessionRef.hasPrefix("sha256:"),
              sessionRef.count > "sha256:".count else {
            throw CrossnetControlFailure.internalError("session_ref_required")
        }
    }
}

/// The typed navigation vocabulary exposed over `crossnet-control/1`.
///
/// The wire vocabulary is owned here so the operator surface cannot silently
/// grow a destination the app never mapped; the app layer maps these onto its
/// own sidebar items and the coordinator's read-back confirms what the UI
/// actually presented.
public enum CrossnetControlNavigationDestination: String, Codable, CaseIterable, Sendable {
    case dashboard
    case deviceManagement = "device_management"
    case usbDeviceManagement = "usb_device_management"
    case fileTransfer = "file_transfer"
    case remoteDesktop = "remote_desktop"
    case quantumCommunication = "quantum_communication"
    case systemMonitor = "system_monitor"
    case settings

    public static func parse(params: CrossnetControlParams) throws
        -> CrossnetControlNavigationDestination {
        guard let raw = params.string("destination"),
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              let destination = CrossnetControlNavigationDestination(rawValue: raw) else {
            throw CrossnetControlFailure.navigationDestinationInvalid
        }
        return destination
    }
}

/// Result of `crossnet.navigate` — the destination the UI actually presented.
public struct CrossnetControlNavigateResult: Codable, Equatable, Sendable {
    public let runtimeTarget: String
    public let controlEffect: String
    public let destination: String
    public let presentedDestination: String
    public let runtimeApplied: Bool

    public init(
        runtimeTarget: String = "mac_app_runtime",
        controlEffect: String = "mac_ui_navigation",
        destination: String,
        presentedDestination: String,
        runtimeApplied: Bool
    ) {
        self.runtimeTarget = runtimeTarget
        self.controlEffect = controlEffect
        self.destination = destination
        self.presentedDestination = presentedDestination
        self.runtimeApplied = runtimeApplied
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeTarget = "runtime_target"
        case controlEffect = "control_effect"
        case destination
        case presentedDestination = "presented_destination"
        case runtimeApplied = "runtime_applied"
    }
}

/// One online account device, redacted for the operator surface.
///
/// `deviceRef` is the only identifier that crosses the wire; raw device ids,
/// IP addresses, MAC addresses, and serial numbers never do.
public struct CrossnetControlDeviceEntry: Codable, Equatable, Sendable {
    public let deviceRef: String
    public let name: String
    public let platform: String?
    public let online: Bool

    public init(deviceRef: String, name: String, platform: String?, online: Bool) {
        self.deviceRef = deviceRef
        self.name = name
        self.platform = platform
        self.online = online
    }

    private enum CodingKeys: String, CodingKey {
        case deviceRef = "device_ref"
        case name
        case platform
        case online
    }
}

/// Result of `crossnet.devices`.
public struct CrossnetControlDevicesResult: Codable, Equatable, Sendable {
    public let runtimeTarget: String
    public let controlEffect: String
    public let devices: [CrossnetControlDeviceEntry]

    public init(
        runtimeTarget: String = "mac_app_runtime",
        controlEffect: String = "read_only",
        devices: [CrossnetControlDeviceEntry]
    ) {
        self.runtimeTarget = runtimeTarget
        self.controlEffect = controlEffect
        self.devices = devices
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeTarget = "runtime_target"
        case controlEffect = "control_effect"
        case devices
    }
}

/// Result of `crossnet.connect_device` — the one-click join outcome.
public struct CrossnetControlConnectDeviceResult: Codable, Equatable, Sendable {
    public let runtimeTarget: String
    public let controlEffect: String
    public let deviceRef: String
    public let name: String?
    public let connected: Bool

    public init(
        runtimeTarget: String = "mac_app_runtime",
        controlEffect: String = "mac_session_mutation",
        deviceRef: String,
        name: String?,
        connected: Bool
    ) {
        self.runtimeTarget = runtimeTarget
        self.controlEffect = controlEffect
        self.deviceRef = deviceRef
        self.name = name
        self.connected = connected
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeTarget = "runtime_target"
        case controlEffect = "control_effect"
        case deviceRef = "device_ref"
        case name
        case connected
    }
}

/// Fail-closed validation for the online-device surface.
public enum CrossnetControlDevicePolicy {
    public static func validate(
        _ result: CrossnetControlDevicesResult
    ) throws -> CrossnetControlDevicesResult {
        guard result.runtimeTarget == "mac_app_runtime" else {
            throw CrossnetControlFailure.internalError("devices_invalid_runtime")
        }
        guard result.controlEffect == "read_only" else {
            throw CrossnetControlFailure.internalError("devices_not_read_only")
        }
        var seen = Set<String>()
        for device in result.devices {
            guard device.deviceRef.hasPrefix("sha256:"),
                  device.deviceRef.count > "sha256:".count else {
                throw CrossnetControlFailure.internalError("devices_unredacted_ref")
            }
            guard seen.insert(device.deviceRef).inserted else {
                throw CrossnetControlFailure.internalError("devices_duplicate_ref")
            }
        }
        return result
    }

    public static func parseDeviceRef(params: CrossnetControlParams) throws -> String {
        guard let raw = params.string("device_ref"),
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("sha256:"),
              raw.count > "sha256:".count else {
            throw CrossnetControlFailure.malformedRequest("invalid device_ref")
        }
        return raw
    }

    public static func validate(
        _ result: CrossnetControlConnectDeviceResult,
        request deviceRef: String
    ) throws -> CrossnetControlConnectDeviceResult {
        guard result.runtimeTarget == "mac_app_runtime" else {
            throw CrossnetControlFailure.internalError("connect_device_invalid_runtime")
        }
        guard result.controlEffect == "mac_session_mutation" else {
            throw CrossnetControlFailure.internalError("connect_device_invalid_effect")
        }
        guard result.deviceRef == deviceRef else {
            throw CrossnetControlFailure.internalError("connect_device_ref_mismatch")
        }
        // A dial the device manager does not read back as connected is not a
        // join, whatever the coordinator returned.
        guard result.connected else {
            throw CrossnetControlFailure.sessionRuntimeApplyFailed
        }
        return result
    }
}

/// Fail-closed validation for `crossnet.navigate`.
///
/// Navigation read-back is inherently the UI's own confirmation: the router
/// refuses to report a navigation the view did not confirm presenting.
public enum CrossnetControlNavigationPolicy {
    public static func validate(
        _ result: CrossnetControlNavigateResult,
        request destination: CrossnetControlNavigationDestination
    ) throws -> CrossnetControlNavigateResult {
        guard result.runtimeTarget == "mac_app_runtime" else {
            throw CrossnetControlFailure.internalError("navigation_invalid_runtime")
        }
        guard result.controlEffect == "mac_ui_navigation" else {
            throw CrossnetControlFailure.internalError("navigation_invalid_effect")
        }
        guard result.destination == destination.rawValue else {
            throw CrossnetControlFailure.internalError("navigation_destination_mismatch")
        }
        guard CrossnetControlNavigationDestination(rawValue: result.presentedDestination) != nil
        else {
            throw CrossnetControlFailure.internalError("navigation_unknown_presented")
        }
        guard result.runtimeApplied, result.presentedDestination == destination.rawValue else {
            throw CrossnetControlFailure.navigationApplyFailed
        }
        return result
    }
}

public struct CrossnetControlStatusResult: Codable, Equatable, Sendable {
    public let connectionStatus: String
    public let readiness: String
    public let sessionPresent: Bool
    public let sessionRef: String?
    public let suite: String?
    public let signalingHealth: String?
    public let failureCode: CrossnetControlStatusFailureCode?
    public let failureClass: CrossnetControlStatusFailureClass?
    public let authLoaded: Bool
    public let tenantBound: Bool

    public init(
        connectionStatus: String,
        readiness: String,
        sessionPresent: Bool,
        sessionRef: String?,
        suite: String?,
        signalingHealth: String?,
        failureCode: CrossnetControlStatusFailureCode? = nil,
        failureClass: CrossnetControlStatusFailureClass? = nil,
        authLoaded: Bool,
        tenantBound: Bool
    ) {
        self.connectionStatus = connectionStatus
        self.readiness = readiness
        self.sessionPresent = sessionPresent
        self.sessionRef = sessionRef
        self.suite = suite
        self.signalingHealth = signalingHealth
        self.failureCode = failureCode
        self.failureClass = failureClass
        self.authLoaded = authLoaded
        self.tenantBound = tenantBound
    }

    private enum CodingKeys: String, CodingKey {
        case connectionStatus = "connection_status"
        case readiness
        case sessionPresent = "session_present"
        case sessionRef = "session_ref"
        case suite
        case signalingHealth = "signaling_health"
        case failureCode = "failure_code"
        case failureClass = "failure_class"
        case authLoaded = "auth_loaded"
        case tenantBound = "tenant_bound"
    }
}

public enum CrossnetControlStatusFailureCode: String, Codable, Equatable, Sendable {
    case authRequired = "auth_required"
    case tenantRequired = "tenant_required"
    case runtimeFailed = "runtime_failed"
}

public enum CrossnetControlStatusFailureClass: String, Codable, Equatable, Sendable {
    case operatorPrecondition = "operator_precondition"
    case runtimeFailure = "runtime_failure"
}

public struct CrossnetControlSettingSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let valueType: String
    public let value: CrossnetControlJSONValue
    public let mutable: Bool
    public let note: String?

    public init(
        id: String,
        valueType: String,
        value: CrossnetControlJSONValue,
        mutable: Bool,
        note: String? = nil
    ) {
        self.id = id
        self.valueType = valueType
        self.value = value
        self.mutable = mutable
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case valueType = "value_type"
        case value
        case mutable
        case note
    }
}

public struct CrossnetControlSettingsSnapshotResult: Codable, Equatable, Sendable {
    public let runtimeTarget: String
    public let controlEffect: String
    public let settings: [CrossnetControlSettingSnapshot]

    public init(
        runtimeTarget: String = "mac_app_runtime",
        controlEffect: String = "read_only",
        settings: [CrossnetControlSettingSnapshot]
    ) {
        self.runtimeTarget = runtimeTarget
        self.controlEffect = controlEffect
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeTarget = "runtime_target"
        case controlEffect = "control_effect"
        case settings
    }
}

enum CrossnetControlSettingsProjectionPolicy {
    static let allowedSettingIDs: Set<String> = [
        "logging.verbose",
        "logging.level",
        "ui.show_realtime_fps",
        "ui.top_bar_ip_location",
        "ui.top_bar_network_speed",
        "ui.top_bar_network_latency",
        "pqc.prefer_xwing_hybrid",
        "pqc.signature_algorithm",
        "remote_desktop.target_fps",
        "remote_desktop.resolution"
    ]

    /// `ScreenCaptureKitStreamer` reads its target size and frame rate only in
    /// `start(...)` and refuses to restart while running, so writing these
    /// changes what the NEXT capture uses — it does not retune a live stream.
    /// The note is part of the wire contract so an operator is never told a
    /// running session was reconfigured.
    static let remoteDesktopCaptureNote = "applies_at_next_capture_start"

    static let allowedRemoteDesktopFrameRates: Set<Int> = [30, 60, 120]

    static func validate(
        _ snapshot: CrossnetControlSettingsSnapshotResult
    ) throws -> CrossnetControlSettingsSnapshotResult {
        guard snapshot.runtimeTarget == "mac_app_runtime" else {
            throw CrossnetControlFailure.internalError("settings_projection_invalid_runtime")
        }
        guard snapshot.controlEffect == "read_only" else {
            throw CrossnetControlFailure.internalError("settings_projection_not_read_only")
        }

        var seenSettingIDs = Set<String>()
        for setting in snapshot.settings {
            guard seenSettingIDs.insert(setting.id).inserted else {
                throw CrossnetControlFailure.internalError("settings_projection_duplicate_id")
            }
            guard allowedSettingIDs.contains(setting.id) else {
                throw CrossnetControlFailure.internalError("settings_projection_not_allowlisted")
            }
            guard setting.mutable == false else {
                throw CrossnetControlFailure.internalError("settings_projection_mutable")
            }
            guard setting.valueType == setting.value.valueType else {
                throw CrossnetControlFailure.internalError("settings_projection_value_type_mismatch")
            }
            try validateValueDomain(setting)
        }

        return snapshot
    }

    private static func validateValueDomain(_ setting: CrossnetControlSettingSnapshot) throws {
        switch setting.id {
        case "logging.verbose",
             "ui.show_realtime_fps",
             "ui.top_bar_ip_location",
             "ui.top_bar_network_speed",
             "ui.top_bar_network_latency":
            guard case .bool = setting.value else {
                throw CrossnetControlFailure.internalError("settings_projection_invalid_value")
            }
            try validateNote(nil, for: setting)
        case "pqc.prefer_xwing_hybrid":
            guard case .bool = setting.value else {
                throw CrossnetControlFailure.internalError("settings_projection_invalid_value")
            }
            try validateNote("policy_preference_not_runtime_proof", for: setting)
        case "logging.level":
            guard case .string(let value) = setting.value,
                  isValidLoggingLevel(value) else {
                throw CrossnetControlFailure.internalError("settings_projection_invalid_value")
            }
            try validateNote(nil, for: setting)
        case "pqc.signature_algorithm":
            guard case .string(let value) = setting.value,
                  isValidPQCSignatureAlgorithm(value) else {
                throw CrossnetControlFailure.internalError("settings_projection_invalid_value")
            }
            try validateNote("policy_preference_not_runtime_proof", for: setting)
        case "remote_desktop.target_fps":
            guard case .int(let value) = setting.value,
                  allowedRemoteDesktopFrameRates.contains(value) else {
                throw CrossnetControlFailure.internalError("settings_projection_invalid_value")
            }
            try validateNote(remoteDesktopCaptureNote, for: setting)
        case "remote_desktop.resolution":
            guard case .string(let value) = setting.value,
                  ResolutionSetting(rawValue: value) != nil else {
                throw CrossnetControlFailure.internalError("settings_projection_invalid_value")
            }
            try validateNote(remoteDesktopCaptureNote, for: setting)
        default:
            throw CrossnetControlFailure.internalError("settings_projection_not_allowlisted")
        }
    }

    private static func validateNote(
        _ expectedNote: String?,
        for setting: CrossnetControlSettingSnapshot
    ) throws {
        guard setting.note == expectedNote else {
            throw CrossnetControlFailure.internalError("settings_projection_invalid_note")
        }
    }

    private static func isValidLoggingLevel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "trace",
            "debug",
            "info",
            "warning",
            "warn",
            "error",
            "critical",
            "fault"
        ].contains(normalized)
    }

    private static func isValidPQCSignatureAlgorithm(_ value: String) -> Bool {
        value == "ML-DSA-65" || value == "ML-DSA-87"
    }
}

/// Result of a `crossnet.settings.set` mutation.
///
/// This is deliberately a distinct type from ``CrossnetControlSettingsSnapshotResult``
/// rather than a relaxation of it: the read projection stays pinned to
/// `control_effect == "read_only"` with every entry `mutable == false`, on both
/// the Swift and Rust sides, so adding mutation cannot loosen the read contract.
///
/// `observedValue` is re-read from the live runtime *after* the write, and
/// `runtimeApplied` records whether the runtime apply hook ran. A mutation is
/// only reported when the observed value equals the requested value; otherwise
/// the router fails closed with `setting_runtime_apply_failed`.
public struct CrossnetControlSettingsMutationResult: Codable, Equatable, Sendable {
    public let runtimeTarget: String
    public let controlEffect: String
    public let id: String
    public let valueType: String
    public let requestedValue: CrossnetControlJSONValue
    public let observedValue: CrossnetControlJSONValue
    public let runtimeApplied: Bool
    public let note: String?

    public init(
        runtimeTarget: String = "mac_app_runtime",
        controlEffect: String = "mac_runtime_mutation",
        id: String,
        valueType: String,
        requestedValue: CrossnetControlJSONValue,
        observedValue: CrossnetControlJSONValue,
        runtimeApplied: Bool,
        note: String? = nil
    ) {
        self.runtimeTarget = runtimeTarget
        self.controlEffect = controlEffect
        self.id = id
        self.valueType = valueType
        self.requestedValue = requestedValue
        self.observedValue = observedValue
        self.runtimeApplied = runtimeApplied
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeTarget = "runtime_target"
        case controlEffect = "control_effect"
        case id
        case valueType = "value_type"
        case requestedValue = "requested_value"
        case observedValue = "observed_value"
        case runtimeApplied = "runtime_applied"
        case note
    }
}

/// A validated `crossnet.settings.set` request.
public struct CrossnetControlSettingsMutationRequest: Equatable, Sendable {
    public let id: String
    public let value: CrossnetControlJSONValue

    public init(id: String, value: CrossnetControlJSONValue) {
        self.id = id
        self.value = value
    }
}

enum CrossnetControlSettingsMutationPolicy {
    /// Settings an operator may change over this channel.
    ///
    /// This is a strict subset of ``CrossnetControlSettingsProjectionPolicy/allowedSettingIDs``:
    /// readability does not imply mutability.
    static let mutableSettingIDs: Set<String> = [
        "logging.verbose",
        "logging.level",
        "ui.show_realtime_fps",
        "ui.top_bar_ip_location",
        "ui.top_bar_network_speed",
        "ui.top_bar_network_latency",
        "remote_desktop.target_fps",
        "remote_desktop.resolution"
    ]

    /// Readable settings whose real authority is the versioned protocol identity
    /// configuration, not a UserDefaults toggle.
    ///
    /// `pqc.signature_algorithm` is committed through a prepare/commit request
    /// generation that can require peer re-pinning, and `pqc.prefer_xwing_hybrid`
    /// is a policy preference rather than runtime proof. Flipping either from a
    /// one-shot control call would report a change the handshake has not made, so
    /// both are refused with an explicit reason instead of being silently absent.
    static let protocolIdentityBoundSettingIDs: Set<String> = [
        "pqc.prefer_xwing_hybrid",
        "pqc.signature_algorithm"
    ]

    static let protocolIdentityRejectionReason =
        "protocol identity settings must be committed through the Mac app's prepare/commit "
        + "protocol identity configuration flow, which can require peer re-pinning; "
        + "a one-shot control write cannot prove the handshake adopted it"

    /// Parses and validates the mutation request, failing closed on unknown ids,
    /// immutable ids, and out-of-domain values.
    static func parse(params: CrossnetControlParams) throws -> CrossnetControlSettingsMutationRequest {
        guard let id = params.string("id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            throw CrossnetControlFailure.malformedRequest("missing setting id")
        }
        if protocolIdentityBoundSettingIDs.contains(id) {
            throw CrossnetControlFailure.settingImmutable(protocolIdentityRejectionReason)
        }
        guard mutableSettingIDs.contains(id) else {
            throw CrossnetControlFailure.settingNotFound
        }

        let value = try mutableValue(for: id, params: params)
        return CrossnetControlSettingsMutationRequest(id: id, value: value)
    }

    private static func mutableValue(
        for id: String,
        params: CrossnetControlParams
    ) throws -> CrossnetControlJSONValue {
        switch id {
        case "logging.verbose",
             "ui.show_realtime_fps",
             "ui.top_bar_ip_location",
             "ui.top_bar_network_speed",
             "ui.top_bar_network_latency":
            guard let value = params.bool("value") else {
                throw CrossnetControlFailure.settingInvalidValue
            }
            return .bool(value)
        case "logging.level":
            guard let raw = params.string("value") else {
                throw CrossnetControlFailure.settingInvalidValue
            }
            guard let canonical = canonicalLoggingLevel(raw) else {
                throw CrossnetControlFailure.settingInvalidValue
            }
            return .string(canonical)
        case "remote_desktop.target_fps":
            guard let value = params.int("value"),
                  CrossnetControlSettingsProjectionPolicy
                      .allowedRemoteDesktopFrameRates.contains(value) else {
                throw CrossnetControlFailure.settingInvalidValue
            }
            return .int(value)
        case "remote_desktop.resolution":
            // Only presets the app can actually represent are accepted; a
            // preset the CLI knows but `ResolutionSetting` cannot express must
            // be refused rather than silently coerced to `auto`.
            guard let raw = params.string("value"),
                  ResolutionSetting(rawValue: raw) != nil else {
                throw CrossnetControlFailure.settingInvalidValue
            }
            return .string(raw)
        default:
            throw CrossnetControlFailure.settingNotFound
        }
    }

    /// Normalizes an operator-supplied level to the exact casing the runtime
    /// stores, so the post-write read-back comparison is meaningful.
    static func canonicalLoggingLevel(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "trace": return "Trace"
        case "debug": return "Debug"
        case "info": return "Info"
        case "warning", "warn": return "Warning"
        case "error": return "Error"
        case "critical": return "Critical"
        case "fault": return "Fault"
        default: return nil
        }
    }

    /// Fails closed unless the runtime read-back matches the requested value.
    static func validate(
        _ result: CrossnetControlSettingsMutationResult,
        request: CrossnetControlSettingsMutationRequest
    ) throws -> CrossnetControlSettingsMutationResult {
        guard result.runtimeTarget == "mac_app_runtime" else {
            throw CrossnetControlFailure.internalError("settings_mutation_invalid_runtime")
        }
        guard result.controlEffect == "mac_runtime_mutation" else {
            throw CrossnetControlFailure.internalError("settings_mutation_invalid_effect")
        }
        guard result.id == request.id else {
            throw CrossnetControlFailure.internalError("settings_mutation_id_mismatch")
        }
        guard result.requestedValue == request.value else {
            throw CrossnetControlFailure.internalError("settings_mutation_request_mismatch")
        }
        guard result.valueType == request.value.valueType else {
            throw CrossnetControlFailure.internalError("settings_mutation_value_type_mismatch")
        }
        guard result.runtimeApplied, result.observedValue == request.value else {
            throw CrossnetControlFailure.settingRuntimeApplyFailed
        }
        return result
    }
}

public enum CrossnetControlSessionRef {
    public static func redacted(_ sessionID: String) -> String {
        let digest = SHA256.hash(data: Data(sessionID.utf8))
        return "sha256:" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension CrossnetControlJSONValue {
    /// Canonical wire name for the payload's value type.
    ///
    /// `CrossnetControlSettingSnapshot.valueType` and
    /// `CrossnetControlSettingsMutationResult.valueType` are already public and must be
    /// filled from this single source of truth, including by the app-layer runtime
    /// factory. Keeping it internal forced either a duplicate mapping outside the module
    /// or an unbuildable app target.
    public var valueType: String {
        switch self {
        case .string:
            return "string"
        case .bool:
            return "bool"
        case .int:
            return "int"
        case .null:
            return "null"
        }
    }
}

private struct CrossnetControlRequestEnvelope: Decodable {
    let v: Int
    let id: String
    let method: String
    let params: CrossnetControlParams?
}

private struct CrossnetControlSuccessEnvelope<Result: Encodable>: Encodable {
    let v: Int
    let id: String
    let ok = true
    let result: Result
}

private struct CrossnetControlFailureEnvelope: Encodable {
    let v: Int
    let id: String?
    let ok = false
    let error: CrossnetControlErrorBody
}

private struct CrossnetControlErrorBody: Encodable {
    let code: String
    let message: String
}

private struct CrossnetControlEventEnvelope<Payload: Encodable>: Encodable {
    let v: Int
    let event: String
    let data: Payload
}
