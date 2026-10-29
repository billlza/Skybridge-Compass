import Foundation

/// Carried only by authenticated CONTROL in the exact session that committed the configuration.
public struct RemoteDesktopSessionTermination: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public enum Reason: String, Codable, Sendable {
        case userStopped
        case permissionRevoked
        case captureFailed
        public var isFailure: Bool { self == .captureFailed }
    }
    public let version: Int
    public let transaction: RemoteDesktopStreamConfigurationTransaction
    public let reason: Reason

    public init(transaction: RemoteDesktopStreamConfigurationTransaction, reason: Reason) {
        version = Self.currentVersion
        self.transaction = transaction
        self.reason = reason
    }
    private enum CodingKeys: String, CodingKey { case version, transaction, reason }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw ValidationError.unsupportedVersion }
        transaction = try values.decode(RemoteDesktopStreamConfigurationTransaction.self, forKey: .transaction)
        reason = try values.decode(Reason.self, forKey: .reason)
    }
    public enum ValidationError: Error, Equatable { case unsupportedVersion, notNegotiated, wrongTransaction }
}

/// A committed receipt, retained across a pending video refresh and retired with its transport owner.
public struct RemoteDesktopSessionTerminationContract: Equatable, Sendable {
    public let transaction: RemoteDesktopStreamConfigurationTransaction
    public init?(acknowledgement: RemoteDesktopStreamConfigurationAcknowledgement) {
        self.init(version: acknowledgement.sessionTerminationVersion, transaction: acknowledgement.transaction)
    }
    public init?(version: Int?, transaction: RemoteDesktopStreamConfigurationTransaction?) {
        guard version == RemoteDesktopSessionTermination.currentVersion, let transaction else { return nil }
        self.transaction = transaction
    }
    public func validate(_ termination: RemoteDesktopSessionTermination) throws {
        guard termination.version == RemoteDesktopSessionTermination.currentVersion else {
            throw RemoteDesktopSessionTermination.ValidationError.unsupportedVersion
        }
        guard termination.transaction == transaction else { throw RemoteDesktopSessionTermination.ValidationError.wrongTransaction }
    }
    public static func negotiatedVersion(requested: Int?) throws -> Int? {
        guard let requested else { return nil }
        guard requested == RemoteDesktopSessionTermination.currentVersion else {
            throw RemoteDesktopSessionTermination.ValidationError.unsupportedVersion
        }
        return requested
    }
    public static func acknowledgementMatches(requested: Int?, acknowledged: Int?) -> Bool {
        // Absence is an old endpoint, never evidence of support for sessionEnded.
        acknowledged == nil || (requested == RemoteDesktopSessionTermination.currentVersion && acknowledged == requested)
    }
}
