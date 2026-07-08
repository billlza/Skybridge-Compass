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
            source.contains("code=\\(existing"),
            "A connection code is an admission secret and must not be logged in plaintext when regenerating."
        )
        XCTAssertFalse(
            source.contains("code=\\(code"),
            "A connection code is an admission secret and must not be logged in plaintext when expiring."
        )
        XCTAssertTrue(
            source.contains("code=<redacted>"),
            "Connection-code lifecycle logs may expose stable reasons, but never the raw user-entered or server-issued code."
        )
        XCTAssertFalse(
            source.contains("activeSessionID == sessionID,\n               self.currentRole == .offerer"),
            "Connection-code lease expiry must only remove stale UI/code state; it must not close an active or in-flight WebRTC session."
        )
    }

    func testPreSessionSignalingFramesAreBoundedAndDrainedAfterSessionStart() throws {
        let source = try Self.crossNetworkWebRTCManagerSource()

        XCTAssertTrue(source.contains("maxPendingPreSessionSignalingEnvelopes = 32"))
        XCTAssertTrue(source.contains("pendingPreSessionSignalingEnvelopesBySessionId"))
        XCTAssertTrue(source.contains("pending.count < Self.maxPendingPreSessionSignalingEnvelopes"))
        XCTAssertTrue(source.contains("state = .failed(message)"))
        XCTAssertTrue(source.contains("pre-session-queued"))
        XCTAssertTrue(source.contains("pre-session-drain"))
        XCTAssertTrue(source.contains("case .offer, .answer, .iceCandidate:\n            return true"))

        XCTAssertTrue(source.contains("guard let session else {\n                    enqueuePreSessionSignalingEnvelope(env)\n                    return\n                }\n                session.setRemoteOffer(sdp)"))
        XCTAssertTrue(source.contains("guard let session else {\n                    enqueuePreSessionSignalingEnvelope(env)\n                    return\n                }\n                session.setRemoteAnswer(sdp)"))
        XCTAssertTrue(source.contains("guard let session else {\n                    enqueuePreSessionSignalingEnvelope(env)\n                    return\n                }\n                session.addRemoteICECandidate"))
        XCTAssertFalse(source.contains("session?.setRemoteOffer"))
        XCTAssertFalse(source.contains("session?.setRemoteAnswer"))
        XCTAssertFalse(source.contains("session?.addRemoteICECandidate"))

        let sessionStart = try XCTUnwrap(source.range(of: "try s.start()"))
        let drain = try XCTUnwrap(source.range(of: "drainPendingPreSessionSignalingEnvelopes(sessionId: sessionId)"))
        let join = try XCTUnwrap(source.range(of: "await sendEnvelope(WebRTCSignalingEnvelope(sessionId: sessionId, from: localId, type: .join"))

        XCTAssertLessThan(sessionStart.lowerBound, drain.lowerBound)
        XCTAssertLessThan(drain.lowerBound, join.lowerBound)
    }

    func testTenantIDPrefersJWTDerivedTenantBeforeUserIdentifierFallback() throws {
        let source = try Self.crossNetworkSignalServerClientSource()

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
        let managerSource = try Self.crossNetworkWebRTCManagerSource()
        let rebindPolicySource = try Self.crossNetworkWebRTCRebindPolicySource()
        let handshakePolicySource = try Self.crossNetworkWebRTCPQCHandshakePolicySource()
        let source = managerSource + "\n" + rebindPolicySource + "\n" + handshakePolicySource

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

    func testIOSDeviceSupportGateKeepsExplicit2018And2019A12FamilyDevicesAppStartSupported() {
        let legacyA12Devices = [
            "iPhone11,2": "iPhone XS",
            "iPhone11,8": "iPhone XR",
            "iPad8,1": "iPad Pro 11-inch (2018)",
            "iPad11,3": "iPad Air (3rd generation)"
        ]

        for (modelIdentifier, displayName) in legacyA12Devices {
            XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: modelIdentifier))
            XCTAssertTrue(IOSDeviceSupportGate.isLegacyLimited(modelIdentifier: modelIdentifier))
            XCTAssertEqual(
                IOSDeviceSupportGate.legacyLimitedDevice(forModelIdentifier: modelIdentifier),
                LegacyLimitedIOSDevice(modelIdentifier: modelIdentifier, displayName: displayName)
            )
        }
    }

    func testIOSDeviceSupportGateAllows2020AndLaterDevices() {
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone12,8"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone13,2"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad11,6"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad13,1"))
        XCTAssertFalse(IOSDeviceSupportGate.isLegacyLimited(modelIdentifier: "iPhone12,8"))
        XCTAssertFalse(IOSDeviceSupportGate.isLegacyLimited(modelIdentifier: "iPhone13,2"))
        XCTAssertFalse(IOSDeviceSupportGate.isLegacyLimited(modelIdentifier: "iPad11,6"))
        XCTAssertFalse(IOSDeviceSupportGate.isLegacyLimited(modelIdentifier: "iPad13,1"))
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

    func testAuthSessionStrictLoaderDistinguishesMissingCorruptAndValidData() throws {
        let keychain = KeychainManager.shared
        keychain.deleteAuthSession()
        defer { keychain.deleteAuthSession() }

        XCTAssertNil(try keychain.loadAuthSessionStrict())

        try keychain.savePublicKey(Data("not-json".utf8), identifier: "auth.session")
        XCTAssertThrowsError(try keychain.loadAuthSessionStrict()) { error in
            guard case KeychainError.decodingError = error else {
                return XCTFail("Expected corrupt auth.session data to throw KeychainError.decodingError, got \(error).")
            }
        }

        let expected = AuthSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            userIdentifier: "user-123",
            displayName: "Primary User",
            email: "primary@example.com",
            avatarURL: "https://example.com/avatar.png",
            nebulaId: "NEBULA-123",
            issuedAt: Date(timeIntervalSince1970: 1_234_567)
        )
        try keychain.storeAuthSession(expected)

        XCTAssertEqual(try keychain.loadAuthSessionStrict(), expected)
    }

    func testKeychainAuthSessionStorageUsesUpdateFirstAndStrictDecoding() throws {
        let source = try Self.keychainManagerSource()

        XCTAssertTrue(
            source.contains("SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)"),
            "Generic password writes should update existing Keychain items before adding missing items."
        )
        XCTAssertFalse(
            source.contains("SecItemDelete(query as CFDictionary)\n        let status = SecItemAdd(query as CFDictionary, nil)"),
            "Generic password writes must not delete an existing auth item before adding its replacement."
        )
        XCTAssertTrue(
            source.contains("nonisolated func loadAuthSessionStrict() throws -> AuthSession?"),
            "Critical auth paths need a throwing loader so corrupt storage is not collapsed into a signed-out state."
        )
        XCTAssertTrue(
            source.contains("throw KeychainError.decodingError"),
            "Corrupt auth.session JSON must surface as a decoding error instead of nil."
        )
    }

    func testKeychainConfigFallbackDoesNotMaskStorageErrors() throws {
        let source = try Self.keychainManagerSource()

        XCTAssertTrue(
            source.contains("public nonisolated func exportKeyStrict(service: String, account: String) throws -> Data?"),
            "Service/account Keychain reads need a strict API so callers can distinguish missing items from OSStatus failures."
        )
        XCTAssertTrue(
            source.contains("throw KeychainError.unexpectedError(status)"),
            "Unexpected Keychain OSStatus values must propagate instead of collapsing to nil."
        )
        XCTAssertTrue(
            source.contains("} catch KeychainError.itemNotFound {\n            // Fallback: macOS-style keys (service-based)"),
            "Legacy service-key fallback should only run when the current iOS keys are genuinely absent."
        )
        XCTAssertFalse(
            source.contains("try? storeSupabaseConfig(url: url, anonKey: anon)"),
            "Supabase legacy migration failures must not be silently ignored."
        )
        XCTAssertFalse(
            source.contains("try? storeNebulaConfig(baseURL: baseURL, clientId: clientId, clientSecret: clientSecret)"),
            "Nebula legacy migration failures must not be silently ignored."
        )
    }

    func testSignalingAuthPathFailsClosedOnAuthSessionStorageErrors() throws {
        let source = try Self.crossNetworkSignalServerClientSource()

        XCTAssertTrue(
            source.contains("case authenticationStorageUnavailable(String)"),
            "Signaling admission should expose Keychain/session storage failures distinctly from missing authentication."
        )
        XCTAssertTrue(
            source.contains("try KeychainManager.shared.loadAuthSessionStrict()"),
            "Signaling auth should use the throwing auth-session loader instead of the legacy optional wrapper."
        )
        XCTAssertFalse(
            source.contains("try? KeychainManager.shared.storeAuthSession(merged)"),
            "Refreshed signaling tokens must not continue after Keychain persistence fails."
        )
    }

    func testAuthenticationManagerPersistsSessionBeforePublishingAuthenticatedState() throws {
        let source = try Self.authenticationManagerSource()

        XCTAssertTrue(
            source.contains("try KeychainManager.shared.loadAuthSessionStrict()"),
            "Launch-time auth restoration should distinguish absent sessions from corrupt Keychain data."
        )
        XCTAssertTrue(
            source.contains("try persistSession(session)\n        self.session = session"),
            "Login success should persist the session before publishing authenticated in-memory state."
        )
        XCTAssertFalse(
            source.contains("try? KeychainManager.shared.storeAuthSession"),
            "AuthenticationManager must not silently discard auth-session persistence failures."
        )
    }

    func testIOSPersistentIdentityKeychainFailuresDoNotRegenerateIdentityMaterial() throws {
        let platformSource = try Self.platformAdapterSource()
        let kemStoreSource = try Self.p2pKEMIdentityKeyStoreSource()
        let pqcManagerSource = try Self.pqcCryptoManagerSource()
        let protocolDeviceIdentitySource = try Self.protocolDeviceIdentitySource()

        XCTAssertFalse(
            platformSource.contains("try? loadIdentityKeyFromKeychain"),
            "Platform identity loading must not collapse Keychain failures into missing identity material."
        )
        XCTAssertTrue(
            platformSource.contains("throw SkyBridgeError.keychainError(status: status)") &&
            platformSource.contains("Stored identity key failed self-test"),
            "Platform identity storage must propagate Keychain failures and fail closed on corrupt stored signing keys."
        )
        XCTAssertTrue(
            platformSource.contains("SKYBRIDGE_KEYCHAIN_IN_MEMORY") &&
            platformSource.contains("inMemoryIdentityKeys[tag] = keyData"),
            "Simulator smoke identity storage must honor the same in-memory keychain gate as KeychainManager."
        )
        XCTAssertFalse(
            kemStoreSource.contains("try? keychain.loadPrivateKey") ||
            kemStoreSource.contains("try? keychain.loadPublicKey"),
            "P2P KEM identity storage must only generate when both public and private keys are genuinely absent."
        )
        XCTAssertTrue(
            kemStoreSource.contains("P2P KEM identity keypair is incomplete"),
            "P2P KEM identity storage must fail closed on half-present keypairs."
        )
        XCTAssertTrue(
            pqcManagerSource.contains("private func loadKeysFromKeychain() throws") &&
            pqcManagerSource.contains("PQC primary KEM/signing key set is incomplete"),
            "PQC primary key loading must expose storage errors and partial keysets before generating."
        )
        XCTAssertFalse(
            pqcManagerSource.contains("try? keychainManager.loadPrivateKey") ||
            pqcManagerSource.contains("try? keychainManager.loadPublicKey"),
            "PQC key loading must not use try? to convert Keychain errors into missing keys."
        )
        XCTAssertTrue(
            protocolDeviceIdentitySource.contains("try KeychainManager.shared.getOrGenerateDeviceIdStrict()"),
            "Protocol device identity must use the strict Keychain device ID path so storage failures do not rotate device IDs."
        )
    }

    private static func crossNetworkWebRTCManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func platformAdapterSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/Platform/PlatformAdapter.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func p2pKEMIdentityKeyStoreSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/Trust/P2PKEMIdentityKeyStore.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func pqcCryptoManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/PQCCryptoManager.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func protocolDeviceIdentitySource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/ProtocolDeviceIdentity.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func crossNetworkWebRTCRebindPolicySource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkWebRTCManager+CurrentPathRebindPolicy.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func crossNetworkWebRTCPQCHandshakePolicySource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkWebRTCPQCHandshakePolicy.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func crossNetworkSignalServerClientSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkSignalServerClient.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func keychainManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/Security/KeychainManager.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func authenticationManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/AuthenticationManager.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

}
