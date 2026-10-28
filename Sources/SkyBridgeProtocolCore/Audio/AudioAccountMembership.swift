import Foundation

public enum AudioMembershipError: Error, Equatable, Sendable {
    case invalidIdentity, invalidScope, invalidTime, staleResponse, incompleteList
    case callerNotActive, peerNotActive, selfPlayback, scopeMismatch, expired, clockMovedBackwards
}

/// Separate fields prevent delimiter collisions and prevent a receipt obtained
/// from one configured account authority being reused under another authority.
public struct AudioAccountIdentity: Equatable, Hashable, Sendable {
    public let authority: String
    public let tenantID: String
    public let userID: String
    public var serverScope: String { "\(tenantID)/\(userID)" }

    public init(authority: String, tenantID: String, userID: String) throws {
        for (value, limit) in [(authority, 2048), (tenantID, 256), (userID, 256)] {
            guard !value.isEmpty, value.utf8.count <= limit,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw AudioMembershipError.invalidScope
            }
        }
        self.authority = authority; self.tenantID = tenantID; self.userID = userID
    }
}

/// An identity claim, not an authority. Admission obtains these fields from the
/// exact Finished-verified connection, including its approved canonical device ID.
public struct AudioProtocolIdentity: Equatable, Hashable, Sendable {
    public let deviceID: String
    public let algorithm: ProtocolSigningAlgorithm
    public let fingerprint: String

    public init(deviceID: String, algorithm: ProtocolSigningAlgorithm, fingerprint: String) throws {
        let normalized = try ProtocolIdentityBinding.normalizedDeviceId(deviceID)
        let lower = fingerprint.lowercased()
        guard normalized == deviceID, lower.utf8.count == 64,
              lower.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AudioMembershipError.invalidIdentity
        }
        self.deviceID = deviceID; self.algorithm = algorithm; self.fingerprint = lower
    }

    public init(_ binding: ProtocolIdentityBinding) throws {
        try self.init(deviceID: binding.deviceId, algorithm: binding.protocolSigningAlgorithm,
                      fingerprint: binding.protocolPublicKeyFingerprint)
    }

    public func matches(_ record: AccountDeviceRecord) -> Bool {
        record.deviceId == deviceID && record.protocolSigningAlgorithm == algorithm.rawValue
            && record.protocolPublicKeyFingerprint.lowercased() == fingerprint
    }
}

/// Locally obtained account evidence. Never decode this from a peer or an ordinary
/// device-list cache. It is intentionally not a transferable signed certificate.
/// The native service must bind issuance to an actual authenticated GET and keep
/// the account/connection current across that await and the publication boundary.
public struct AudioAccountMembership: Equatable, Sendable {
    public static let maximumLifetimeMilliseconds: Int64 = 3_600_000
    public static let maximumRequestMilliseconds: Int64 = 30_000
    public let id: UUID
    public let account: AudioAccountIdentity
    public let localIdentity: AudioProtocolIdentity
    public let peerIdentity: AudioProtocolIdentity
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    /// In-process anchors belong to the evidence, not to a connection. Reusing
    /// evidence after reconnect must never create a fresh monotonic lifetime.
    public let issuedAtMonotonic: ContinuousClock.Instant
    public let expiresAtMonotonic: ContinuousClock.Instant

    public static func verifyFreshResponse(
        _ response: AccountDeviceListSnapshot,
        account: AudioAccountIdentity,
        local: AudioProtocolIdentity,
        peer: AudioProtocolIdentity,
        requestStartedMilliseconds: Int64,
        receivedMilliseconds: Int64,
        requestStartedMonotonic: ContinuousClock.Instant,
        receivedMonotonic: ContinuousClock.Instant,
        lifetimeMilliseconds: Int64 = maximumLifetimeMilliseconds
    ) throws -> Self {
        try validateFreshObservation(response, account: account, local: local,
            requestStartedMilliseconds: requestStartedMilliseconds, receivedMilliseconds: receivedMilliseconds,
            requestStartedMonotonic: requestStartedMonotonic, receivedMonotonic: receivedMonotonic)
        guard lifetimeMilliseconds > 0, lifetimeMilliseconds <= maximumLifetimeMilliseconds else {
            throw AudioMembershipError.invalidTime
        }
        guard !response.truncated else { throw AudioMembershipError.incompleteList }
        guard local.deviceID != peer.deviceID else { throw AudioMembershipError.selfPlayback }
        let callers = response.devices.filter { local.matches($0) }
        guard callers.count == 1, callers[0].isCaller, callers[0].status == "active" else {
            throw AudioMembershipError.callerNotActive
        }
        let peers = response.devices.filter { peer.matches($0) }
        guard peers.count == 1, !peers[0].isCaller, peers[0].status == "active" else {
            throw AudioMembershipError.peerNotActive
        }
        // Start validity at request initiation. Reconnect cannot renew either clock.
        let expiry = requestStartedMilliseconds.addingReportingOverflow(lifetimeMilliseconds)
        let monotonicExpiry = requestStartedMonotonic.advanced(by: .milliseconds(lifetimeMilliseconds))
        guard !expiry.overflow, expiry.partialValue > receivedMilliseconds,
              monotonicExpiry > receivedMonotonic else { throw AudioMembershipError.invalidTime }
        return Self(id: UUID(), account: account, localIdentity: local, peerIdentity: peer,
                    issuedAtMilliseconds: requestStartedMilliseconds, expiresAtMilliseconds: expiry.partialValue,
                    issuedAtMonotonic: requestStartedMonotonic, expiresAtMonotonic: monotonicExpiry)
    }

    /// Validate the authenticated GET before using any negative observation. A
    /// truncated list can revoke explicit inactive rows, but cannot prove absence.
    public static func validateFreshObservation(
        _ response: AccountDeviceListSnapshot, account: AudioAccountIdentity, local: AudioProtocolIdentity,
        requestStartedMilliseconds: Int64, receivedMilliseconds: Int64,
        requestStartedMonotonic: ContinuousClock.Instant, receivedMonotonic: ContinuousClock.Instant
    ) throws {
        guard response.accountScope == account.serverScope else { throw AudioMembershipError.scopeMismatch }
        guard requestStartedMilliseconds > 0, receivedMilliseconds >= requestStartedMilliseconds,
              receivedMonotonic >= requestStartedMonotonic else {
            throw AudioMembershipError.invalidTime
        }
        guard receivedMilliseconds - requestStartedMilliseconds <= maximumRequestMilliseconds,
              requestStartedMonotonic.duration(to: receivedMonotonic) <= .milliseconds(maximumRequestMilliseconds) else {
            throw AudioMembershipError.staleResponse
        }
        // A fresh request is mandatory; the server timestamp is an additional
        // skew/stale-response check, not a replacement for that request witness.
        guard response.generatedAtEpochMilliseconds > 0,
              absDifference(response.generatedAtEpochMilliseconds, receivedMilliseconds)
                <= UInt64(maximumRequestMilliseconds) else { throw AudioMembershipError.staleResponse }
        _ = try response.validatedFor(deviceID: local.deviceID, algorithm: local.algorithm.rawValue,
                                      fingerprint: local.fingerprint)
    }

    public static func contradicts(_ response: AccountDeviceListSnapshot,
                                  local: AudioProtocolIdentity, peer: AudioProtocolIdentity) -> Bool {
        [local, peer].contains { identity in
            let records = response.devices.filter { identity.matches($0) }
            return records.contains { $0.status != "active" } || (!response.truncated && records.count != 1)
        }
    }

    public func validate(account: AudioAccountIdentity, local: AudioProtocolIdentity,
                         peer: AudioProtocolIdentity, nowMilliseconds: Int64,
                         monotonicNow: ContinuousClock.Instant = .now) throws {
        guard self.account == account else { throw AudioMembershipError.scopeMismatch }
        guard localIdentity == local, peerIdentity == peer else { throw AudioMembershipError.invalidIdentity }
        guard nowMilliseconds >= issuedAtMilliseconds, monotonicNow >= issuedAtMonotonic else {
            throw AudioMembershipError.clockMovedBackwards
        }
        guard nowMilliseconds < expiresAtMilliseconds, monotonicNow < expiresAtMonotonic else {
            throw AudioMembershipError.expired
        }
    }

    private static func absDifference(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        // Both are positive by the caller's checks; unsigned subtraction avoids
        // signed overflow even for hostile server timestamps near Int64.max.
        lhs >= rhs ? UInt64(lhs) - UInt64(rhs) : UInt64(rhs) - UInt64(lhs)
    }
}

/// The source approved by the receiver. A second offer/configuration requires a
/// new stream and permission; arbitrary later file paths are never part of it.
public enum AudioPlaybackSource: Equatable, Sendable {
    case originalFile(transferID: UUID, length: UInt64, sha256: Data)
    case capturedPCM(AudioStreamingPCMFormat)
    case opus(source: AudioStreamingOpusSource, format: AudioStreamingOpusFormat)

    public init(offer: AudioStreamingMessage) throws {
        _ = try AudioStreamingWire.encode(offer)
        switch offer.body {
        case let .fileOffer(id, length, digest): self = .originalFile(transferID: id, length: length, sha256: digest)
        case let .captureOffer(format): self = .capturedPCM(format)
        case let .opusOffer(source, format): self = .opus(source: source, format: format)
        case let .bufferedOpusFileOffer(format): self = .opus(source: .originalFile, format: format)
        default: throw AudioStreamingWireError.malformed
        }
    }
}
