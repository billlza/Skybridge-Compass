import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
@available(iOS 17.0, *)
final class ConnectionCodeFormatTests: XCTestCase {
    func testSanitizeConnectionCodeInputUppercasesFiltersAndCapsLength() {
        let raw = "ab-cd12 34efghjkmnpqrstuvwxyz23456789"
        let sanitized = CrossNetworkWebRTCManager.sanitizeConnectionCodeInput(raw)

        XCTAssertEqual(sanitized, "ABCD234EFGHJKMNP")
        XCTAssertEqual(sanitized.count, CrossNetworkWebRTCManager.maximumConnectionCodeLength)
    }

    func testCanSubmitConnectionCodeAcceptsLegacyAndCurrentLengths() {
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEF"))
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFGH"))
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFGHJK"))
        XCTAssertFalse(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDE"))
        XCTAssertFalse(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFG"))
    }

    func testConnectionCodeLeaseReuseRequiresUnexpiredServerLease() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            CrossNetworkWebRTCManager.isReusableConnectionCodeLease(
                expiresAt: now.addingTimeInterval(60),
                now: now
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.isReusableConnectionCodeLease(
                expiresAt: now.addingTimeInterval(10),
                now: now
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.isReusableConnectionCodeLease(
                expiresAt: nil,
                now: now
            )
        )
    }

    func testGenerateConnectionCodeDoesNotReuseExpiredWaitingCode() throws {
        let source = try Self.crossNetworkWebRTCManagerSource()

        XCTAssertTrue(
            source.contains("Self.isReusableConnectionCodeLease(expiresAt: localConnectionCodeExpiresAt)"),
            "Displayed connection codes must not be reused after their server lease is expired or near expiry."
        )
        XCTAssertTrue(
            source.contains("scheduleConnectionCodeLeaseInvalidation("),
            "A displayed code should be removed before its server lease becomes non-reusable, avoiding stale UI codes that lookup as found=false."
        )
        XCTAssertTrue(
            source.contains("本地连接码不可复用"),
            "Regenerating an expired or authority-stale displayed code should clean up the stale local offerer state."
        )
        XCTAssertTrue(
            source.contains("connection_code_lease_not_reusable"),
            "Regenerating an expired displayed code should emit a stable cleanup reason for post-release log audits."
        )
        XCTAssertTrue(
            source.contains("connection_code_lease_expired"),
            "The expiry task should emit a stable reason when it removes a displayed stale connection code."
        )
        XCTAssertFalse(
            source.contains("reason=connection_code_lease_not_reusable code=\\(existing)\")\n                await disconnect(clearSnapshot: false)"),
            "Regenerating a stale displayed code should not tear down a session that may already be completing its WebRTC handshake."
        )
        XCTAssertFalse(
            source.contains("activeSessionID == sessionID,\n               self.currentRole == .offerer"),
            "Connection-code lease expiry must only remove stale UI/code state; it must not close an active or in-flight WebRTC session."
        )
    }

    func testTenantIDPrefersJWTDerivedTenantBeforeUserIdentifierFallback() throws {
        let source = try Self.crossNetworkWebRTCManagerSource()

        XCTAssertTrue(
            source.contains("deriveTenantIdentifier(accessToken: sessionAccessToken)"),
            "iOS WebRTC signaling must derive the tenant from the same JWT claims as macOS before falling back to the Supabase user id."
        )
        XCTAssertTrue(
            source.contains("return sessionUserIdentifier"),
            "The user identifier should remain only as a fallback for legacy sessions without tenant-bearing JWT claims."
        )
    }

    func testConnectionCodeLookupAllowsAuthenticatedAuthorityRotation() throws {
        let source = try Self.crossNetworkWebRTCManagerSource()

        XCTAssertTrue(
            source.contains("? .verifiedQRCode\n                : .verifiedConnectionCode"),
            "Connection-code lookup is itself a user-mediated fresh authority proof and must not fall back to unauthenticated rebind handling."
        )
        XCTAssertTrue(
            source.contains("activeConnectionCodeMatchesCurrentAuthority(localBinding)"),
            "A long-lived connection code must be regenerated when the local authoritative key changes."
        )
        XCTAssertTrue(
            source.contains("connection_code_authority_changed"),
            "Stale connection-code regeneration should leave a stable post-release log reason."
        )
        XCTAssertTrue(
            source.contains("let useClassicAuthorityBootstrap ="),
            "Connection-code WebRTC bootstrap must explicitly bind the initial handshake policy to the advertised authority identity."
        )
        XCTAssertTrue(
            source.contains("localConnectionSessionId == sessionId"),
            "The local connection-code offerer must use classic authority bootstrap even when trusted KEM material is available."
        )
        XCTAssertTrue(
            source.contains("authorityBoundWebRTCBootstrapSessionIds.insert(lease.sessionID)"),
            "iOS connection-code and connect-link offerer sessions must be marked as authority-bound for identity-pinned bootstrap."
        )
        XCTAssertTrue(
            source.contains("expectedRemoteAuthorityAlgorithm"),
            "The connection-code joiner must honor the Ed25519 authority fingerprint returned by lookup instead of switching to a PQC identity key."
        )
        XCTAssertTrue(
            source.contains("authorityBootstrap=\\(useClassicAuthorityBootstrap)"),
            "Release logs must expose whether identityMismatch prevention used authority-bound bootstrap."
        )
        XCTAssertTrue(
            source.contains("shouldAllowAuthenticatedConnectionCodeRebind"),
            "Connection codes should have an explicit, narrower rebind policy instead of borrowing QR wording or refusing stale key rotations."
        )
        XCTAssertTrue(
            source.contains("case .identityConflict:\n            return true"),
            "A verified connection code should heal the common stale-key conflict for the same deviceId."
        )
        XCTAssertFalse(
            source.contains("case .verifiedQRCode, .verifiedConnectionCode:"),
            "QR and connection-code rebind policies should stay separate so future hardening can tune them independently."
        )
    }

    func testIOSDeviceSupportGateBlocksExplicit2018And2019A12FamilyDevices() {
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone11,2"))
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone11,8"))
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad8,1"))
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad11,3"))
    }

    func testIOSDeviceSupportGateAllows2020AndLaterDevices() {
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone12,8"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone13,2"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad11,6"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad13,1"))
    }

    func testSupabaseServiceNormalizesRelativeAvatarURLs() {
        let baseURL = URL(string: "https://demo.example.com")!

        XCTAssertEqual(
            SupabaseService.normalizedRemoteAssetURL(
                "/storage/v1/object/public/avatars/user.jpg",
                baseURL: baseURL
            ),
            "https://demo.example.com/storage/v1/object/public/avatars/user.jpg"
        )
        XCTAssertEqual(
            SupabaseService.normalizedRemoteAssetURL(
                "storage/v1/object/public/avatars/user.jpg",
                baseURL: baseURL
            ),
            "https://demo.example.com/storage/v1/object/public/avatars/user.jpg"
        )
        XCTAssertEqual(
            SupabaseService.normalizedRemoteAssetURL(
                "https://cdn.example.com/avatar.jpg",
                baseURL: baseURL
            ),
            "https://cdn.example.com/avatar.jpg"
        )
    }

    func testRemoteUserProfileCarriesAvatarAndNebulaFields() {
        let profile = SupabaseService.RemoteUserProfile(
            userId: "user-1",
            email: "person@example.com",
            displayName: "Primary Name",
            avatarURL: "https://demo.example.com/avatar.jpg",
            nebulaId: "NEBULA-123"
        )

        XCTAssertEqual(profile.userId, "user-1")
        XCTAssertEqual(profile.displayName, "Primary Name")
        XCTAssertEqual(profile.avatarURL, "https://demo.example.com/avatar.jpg")
        XCTAssertEqual(profile.nebulaId, "NEBULA-123")
    }

    private static func crossNetworkWebRTCManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

}
