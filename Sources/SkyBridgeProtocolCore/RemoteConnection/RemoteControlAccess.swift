import Foundation

/// A host-issued input grant carried inside an authenticated stream receipt.
/// The lease identifies one grant, not a device; a later grant always replaces it.
public struct RemoteControlAccess: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public enum Role: String, Codable, Sendable {
        case controller
        case observer
    }

    public let version: Int
    public let revision: UInt64
    public let role: Role
    public let lease: UUID?

    public init(revision: UInt64, role: Role, lease: UUID?) throws {
        guard revision > 0, revision <= UInt64(Int64.max),
              (role == .controller) == (lease != nil) else {
            throw ValidationError.invalidGrant
        }
        version = Self.currentVersion
        self.revision = revision
        self.role = role
        self.lease = lease
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.currentVersion else {
            throw ValidationError.unsupportedVersion
        }
        try self.init(
            revision: values.decode(UInt64.self, forKey: .revision),
            role: values.decode(Role.self, forKey: .role),
            lease: values.decodeIfPresent(UUID.self, forKey: .lease)
        )
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidGrant
        case unsupportedVersion
        case conflictingRevision
        case negotiationChanged
    }

    private enum CodingKeys: String, CodingKey { case version, revision, role, lease }
}

/// Per-authenticated-session negotiation. Absence in the first receipt selects
/// the existing exclusive-controller contract; it cannot downgrade a managed
/// session later. Duplicate receipts are idempotent and stale grants never win.
public struct RemoteControlAccessTracker: Equatable, Sendable {
    public private(set) var hasAcknowledgement = false
    public private(set) var access: RemoteControlAccess?

    public init() {}

    public var canSendInput: Bool {
        hasAcknowledgement && (access == nil || access?.role == .controller)
    }

    @discardableResult
    public mutating func accept(_ incoming: RemoteControlAccess?) throws -> Bool {
        guard hasAcknowledgement else {
            hasAcknowledgement = true
            access = incoming
            return true
        }
        switch (access, incoming) {
        case (nil, nil):
            return false
        case (.some(let previous), .some(let next)):
            if next.revision < previous.revision { return false }
            if next.revision == previous.revision {
                guard next == previous else {
                    throw RemoteControlAccess.ValidationError.conflictingRevision
                }
                return false
            }
            access = next
            return true
        case (nil, .some), (.some, nil):
            throw RemoteControlAccess.ValidationError.negotiationChanged
        }
    }
}
