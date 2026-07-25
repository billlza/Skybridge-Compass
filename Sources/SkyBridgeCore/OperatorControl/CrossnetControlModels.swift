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

    public init(
        engineVersion: String,
        proto: Int = CrossnetControlWire.protocolVersion,
        authLoaded: Bool,
        tenantBound: Bool
    ) {
        self.engineVersion = engineVersion
        self.proto = proto
        self.authLoaded = authLoaded
        self.tenantBound = tenantBound
    }

    private enum CodingKeys: String, CodingKey {
        case engineVersion = "engine_version"
        case proto
        case authLoaded = "auth_loaded"
        case tenantBound = "tenant_bound"
    }
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
        "pqc.signature_algorithm"
    ]

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
        "ui.top_bar_network_latency"
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
