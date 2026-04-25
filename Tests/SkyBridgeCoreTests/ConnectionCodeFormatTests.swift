import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class ConnectionCodeFormatTests: XCTestCase {
    func testSanitizeConnectionCodeInputUppercasesFiltersAndCapsLength() {
        let raw = "ab-cd12 34efghjkmnpqrstuvwxyz23456789"
        let sanitized = CrossNetworkConnectionManager.sanitizeConnectionCodeInput(raw)

        XCTAssertEqual(sanitized, "ABCD234EFGHJKMNP")
        XCTAssertEqual(sanitized.count, CrossNetworkConnectionManager.maximumConnectionCodeLength)
    }

    func testCanSubmitConnectionCodeAcceptsLegacyAndCurrentLengths() {
        XCTAssertTrue(CrossNetworkConnectionManager.canSubmitConnectionCode("ABCDEF"))
        XCTAssertTrue(CrossNetworkConnectionManager.canSubmitConnectionCode("ABCDEFGH"))
        XCTAssertTrue(CrossNetworkConnectionManager.canSubmitConnectionCode("ABCDEFGHJK"))
        XCTAssertFalse(CrossNetworkConnectionManager.canSubmitConnectionCode("ABCDE"))
        XCTAssertFalse(CrossNetworkConnectionManager.canSubmitConnectionCode("ABCDEFG"))
    }

    func testConnectionCodeLeaseReuseRequiresUnexpiredServerLease() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            CrossNetworkConnectionManager.isReusableConnectionCodeLease(
                expiresAt: now.addingTimeInterval(60),
                now: now
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.isReusableConnectionCodeLease(
                expiresAt: now.addingTimeInterval(10),
                now: now
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.isReusableConnectionCodeLease(
                expiresAt: nil,
                now: now
            )
        )
    }

    func testGenerateConnectionCodeDoesNotReuseExpiredWaitingCode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("Self.isReusableConnectionCodeLease(expiresAt: connectionCodeExpiresAt)"),
            "Displayed connection codes must not be reused after their server lease is expired or near expiry."
        )
        XCTAssertTrue(
            source.contains("connection_code_lease_not_reusable"),
            "Regenerating an expired displayed code should clean up the stale waiting WebRTC session."
        )
        XCTAssertTrue(
            source.contains("scheduleConnectionCodeLeaseInvalidation("),
            "A displayed code should be removed before its server lease becomes non-reusable, avoiding stale UI codes that lookup as found=false."
        )
        XCTAssertTrue(
            source.contains("connection_code_lease_expired"),
            "The expiry task should emit a stable reason when it removes a displayed stale connection code."
        )
        XCTAssertFalse(
            source.contains("cleanupWebRTCSession(sessionID, reason: \"connection_code_lease_expired\")"),
            "Connection-code lease expiry must only remove stale UI/code state; it must not close an active or in-flight WebRTC session."
        )
        XCTAssertFalse(
            source.contains("cleanupWebRTCSession(activeConnectionCodeSessionID ?? existing, reason: \"connection_code_lease_not_reusable\")"),
            "Regenerating a stale displayed code should not tear down a session that may already be completing its WebRTC handshake."
        )
    }

    func testConnectionCodeLookupAllowsOnlyAuthenticatedSameDeviceAuthorityRotation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("authenticatedConnectionCodeRebindAllowed: true"),
            "Connection-code lookup should be treated as a fresh authenticated authority proof after admission and lookup succeed."
        )
        XCTAssertTrue(
            source.contains("activeConnectionCodeMatchesCurrentAuthority(localBinding)"),
            "A 24-hour connection code must not be reused after the local authoritative key rotates."
        )
        XCTAssertTrue(
            source.contains("connection_code_authority_changed"),
            "Stale connection codes should log a stable reason when they are regenerated after key rotation."
        )
        XCTAssertTrue(
            source.contains("let useClassicAuthorityBootstrap ="),
            "Connection-code WebRTC bootstrap must explicitly bind the initial handshake policy to the advertised authority identity."
        )
        XCTAssertTrue(
            source.contains("activeConnectionCodeSessionID == sessionID"),
            "The local connection-code offerer must use classic authority bootstrap even when trusted KEM material is available."
        )
        XCTAssertTrue(
            source.contains("currentPathExpectedRemoteAuthorityBySessionId[sessionID]?.protocolSigningAlgorithm == .ed25519"),
            "The connection-code joiner must honor the Ed25519 authority fingerprint returned by lookup instead of switching to a PQC identity key."
        )
        XCTAssertTrue(
            source.contains("authorityBootstrap=\\(useClassicAuthorityBootstrap"),
            "Release logs must expose whether identityMismatch prevention used authority-bound bootstrap."
        )
        XCTAssertTrue(
            source.contains("shouldAllowAuthenticatedConnectionCodeRebind"),
            "Connection-code rebinds need a dedicated policy instead of borrowing QR behavior."
        )
        XCTAssertTrue(
            source.contains("case .identityConflict:\n            return true"),
            "A verified connection code should heal stale authoritative keys for the same deviceId."
        )
        XCTAssertTrue(
            source.contains("case .deviceIdMigrationRequired, .quarantinedIdentity, .revokedIdentity:\n            return false"),
            "Connection codes must still block device-id migration, quarantined identities, and revoked identities."
        )
        XCTAssertFalse(
            source.contains("authenticatedAuthorityRebindAllowed"),
            "The old generic flag made it too easy to accidentally reuse QR policy for connection-code trust repair."
        )
    }
}
