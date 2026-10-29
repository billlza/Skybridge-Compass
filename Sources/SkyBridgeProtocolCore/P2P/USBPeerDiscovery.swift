import Foundation

/// A signed public identity advertisement is a discovery hint, never a trust
/// grant. Enrollment still uses the existing two-sided PIB verification code.
public struct USBPeerDiscoveryRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce: UUID
    public let issuedAtMilliseconds: Int64

    public init(nonce: UUID = UUID(), now: Date = Date()) throws {
        version = 1; self.nonce = nonce
        issuedAtMilliseconds = try Self.milliseconds(now)
    }

    public func validate(now: Date = Date()) throws {
        let current = try Self.milliseconds(now)
        guard version == 1, issuedAtMilliseconds >= current - 30_000,
              issuedAtMilliseconds <= current + 5_000 else { throw USBPeerDiscoveryError.invalidRequest }
    }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value < 9_000_000_000_000_000 else { throw USBPeerDiscoveryError.invalidRequest }
        return Int64(value)
    }
}

public struct USBPeerDiscoveryResponse: Codable, Equatable, Sendable {
    public let request: USBPeerDiscoveryRequest
    public let identity: HandshakeManagementIdentity
    public let name: String
    public let platform: String
    public let signature: Data

    public init(request: USBPeerDiscoveryRequest, identity: HandshakeManagementIdentity,
                name: String, platform: String, signature: Data) {
        self.request = request; self.identity = identity; self.name = name
        self.platform = platform; self.signature = signature
    }

    public var signingData: Data {
        get throws {
            struct Transcript: Encodable {
                let domain = "SkyBridge.USBPeerDiscovery.v1"
                let request: USBPeerDiscoveryRequest
                let identity: HandshakeManagementIdentity
                let name: String
                let platform: String
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(Transcript(request: request, identity: identity, name: name, platform: platform))
        }
    }

    public func validate(for expected: USBPeerDiscoveryRequest, now: Date = Date(),
                         verify: @Sendable (Data, Data, HandshakeManagementIdentity) async throws -> Bool) async throws {
        try expected.validate(now: now)
        guard request == expected, !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ["ios", "macos"].contains(platform), !signature.isEmpty, signature.count <= 8_192 else {
            throw USBPeerDiscoveryError.invalidResponse
        }
        try identity.validate()
        guard try await verify(signingData, signature, identity) else { throw USBPeerDiscoveryError.signatureInvalid }
    }
}

public enum USBPeerDiscoveryError: String, Error, Sendable {
    case invalidRequest, invalidResponse, signatureInvalid, rateLimited
}

/// A small per-owner budget bounds expensive signing and replay work before
/// authentication. Transport admission deadlines remain enforced by the host.
@MainActor
public final class USBPeerDiscoveryResponder {
    private var seen: [UUID: Date] = [:]
    private var inFlight = 0
    public init() {}

    public func respond(to request: USBPeerDiscoveryRequest, name: String, platform: String,
                        identity: @MainActor () async throws -> HandshakeManagementIdentity,
                        sign: @MainActor (Data) async throws -> Data) async throws -> USBPeerDiscoveryResponse {
        try request.validate()
        try Task.checkCancellation()
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 30 }
        guard seen[request.nonce] == nil, seen.count < 32, inFlight < 2 else { throw USBPeerDiscoveryError.rateLimited }
        seen[request.nonce] = now; inFlight += 1
        defer { inFlight -= 1 }
        let identity = try await identity()
        try identity.validate()
        let safeName = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(32))
        guard !safeName.isEmpty, ["ios", "macos"].contains(platform) else { throw USBPeerDiscoveryError.invalidResponse }
        let unsigned = USBPeerDiscoveryResponse(request: request, identity: identity, name: safeName, platform: platform, signature: Data())
        let signature = try await sign(unsigned.signingData)
        try Task.checkCancellation()
        guard !signature.isEmpty, signature.count <= 8_192 else { throw USBPeerDiscoveryError.signatureInvalid }
        try request.validate()
        return USBPeerDiscoveryResponse(request: request, identity: identity, name: safeName, platform: platform, signature: signature)
    }
}
