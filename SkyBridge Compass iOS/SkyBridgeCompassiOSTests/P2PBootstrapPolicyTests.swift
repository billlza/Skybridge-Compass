import XCTest
import CryptoKit
import Network
@testable import SkyBridgeCompass_iOS

final class BonjourServiceIdentitySanitizerTests: XCTestCase {
    func testRejectsSyntheticBonjourIdentityNames() {
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("id:e0715a9a-d0d3-47e6-b353-de0a30293e1f"))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("bonjour:id:e0715a9a-d0d3-47e6-b353-de0a30293e1f@local."))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("host:fe80::1%en0"))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("E0715A9A-D0D3-47E6-B353-DE0A30293E1F"))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("fe80::ce0:3cf9:13d0:85b3%en0"))
    }

    func testAcceptsAndNormalizesRealBonjourInstanceNames() {
        XCTAssertEqual(
            BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("Lza的MacBook Pro._skybridge._tcp"),
            "Lza的MacBook Pro"
        )
        XCTAssertEqual(
            BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("bonjour:Lza的MacBook Pro@local."),
            "Lza的MacBook Pro"
        )
    }
}

@available(iOS 17.0, *)
@MainActor
final class P2PBootstrapPolicyTests: XCTestCase {
    private func readRepositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip(
            "Repository source files are not mounted inside the physical-device test sandbox; run source-shape regression tests on macOS or iOS Simulator."
        )
        #else
        return try String(contentsOf: sourceURL, encoding: .utf8)
        #endif
    }

    func testStrictPQCUsesBootstrapWhenPreferredKEMIsMissing() {
        XCTAssertFalse(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [],
                preferredTargetSuite: .xwing
            )
        )
    }

    func testStrictPQCDoesNotBootstrapWhenPreferredKEMExists() {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.xwing, .mlkem768],
                preferredTargetSuite: .xwing
            )
        )
    }

    func testStrictPQCAllowsAnyPQCTrustWhenNoPreferredSuiteIsPinned() {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.mlkem768],
                preferredTargetSuite: nil
            )
        )
    }

    func testStrictPQCRequiresPreferredHybridKEMWhenPinned() {
        XCTAssertFalse(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.mlkem768],
                preferredTargetSuite: .xwing
            )
        )
    }

    func testStrictPQCRequiresSignedRefreshEvidenceByDefault() throws {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.xwing],
                preferredTargetSuite: .xwing
            )
        )
        XCTAssertFalse(
            P2PConnectionManager.signedRefreshEvidenceSatisfiesStrictPQC(
                nil,
                preferredTargetSuite: .xwing
            )
        )

        let evidence = KEMTrustStore.SignedRefreshEvidence(
            deviceId: "id:signed-refresh-peer",
            suiteWireIds: [CryptoSuite.xwing.wireId],
            source: "signed_lan_kem_refresh",
            keyId: "skr1-test",
            generation: 1,
            expiresAt: Date().addingTimeInterval(60),
            protocolIdentityFingerprint: String(repeating: "a", count: 64),
            signingFingerprint: String(repeating: "a", count: 64),
            payloadHashHex: String(repeating: "b", count: 64),
            updatedAt: Date()
        )
        XCTAssertTrue(
            P2PConnectionManager.signedRefreshEvidenceSatisfiesStrictPQC(
                evidence,
                preferredTargetSuite: .xwing
            )
        )

        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        XCTAssertTrue(source.contains("requiresSignedKEMRefreshEvidenceForStrictPQC"))
        XCTAssertFalse(
            source.contains("SKYBRIDGE_STRICT_PQC_ALLOW_UNSIGNED_LEGACY_KEM"),
            "strictPQC must not expose an unsigned legacy KEM bypass that can mask missing SKR-1 evidence."
        )
        XCTAssertTrue(source.contains("return true"))
        XCTAssertTrue(source.contains("signedRefreshEvidenceSuites(initialSignedRefreshEvidence)"))
    }

    func testStrictOutboundHandshakePassesPinnedTrustProviderToFinalDriver() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("stage: \"outbound\""))
        XCTAssertTrue(source.contains("throw P2PError.missingPinnedProtocolIdentity"))
        XCTAssertTrue(source.contains("trustProvider: strictTrustContext?.provider"))
        XCTAssertTrue(
            source.contains("expectedRemoteSOAPeerId: soaPeerIdBytes(for: strictTrustContext?.stablePeerId ?? peerId) ?? remotePeerId")
        )
        XCTAssertFalse(
            source.contains("trustProvider: nil"),
            "strict outbound P2P must not silently fall back to DefaultHandshakeTrustProvider after preflight."
        )
    }

    func testStrictOutboundSOAUsesResolvedStablePeerInsteadOfEndpointAlias() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private func performPQCHandshake("))
        let end = try XCTUnwrap(source.range(of: "public func rekeyToPreferPQC(", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        let trustContext = try XCTUnwrap(body.range(of: "let strictTrustContext"))
        let target = try XCTUnwrap(body.range(of: "let outboundSOATargetPeerId = strictTrustContext?.stablePeerId ?? peerId"))
        let shouldAdvertise = try XCTUnwrap(body.range(of: "let shouldAdvertiseSOA = allowSOA && (shouldUseSOA(for: device) || canBindSOATarget)"))
        let outboundSOA = try XCTUnwrap(body.range(of: "let outboundSOA: HandshakeSOAMetadata?"))

        XCTAssertLessThan(trustContext.lowerBound, target.lowerBound)
        XCTAssertLessThan(target.lowerBound, shouldAdvertise.lowerBound)
        XCTAssertLessThan(shouldAdvertise.lowerBound, outboundSOA.lowerBound)
        XCTAssertTrue(body.contains("let remotePeerId = shouldAdvertiseSOA ? soaPeerIdBytes(for: outboundSOATargetPeerId) : nil"))
        XCTAssertFalse(
            body.contains("let remotePeerId = shouldAdvertiseSOA ? soaPeerIdBytes(for: device.id) : nil"),
            "Strict outbound SOA must bind to the resolved stable peer id, not the current host/Bonjour endpoint alias."
        )
    }

    func testStrictPreflightMissingKEMWithPinnedIdentityChoosesPIBBeforeSKR() {
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: nil,
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)],
            preferredTargetSuite: .xwing
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testStrictPreflightMissingKEMWithoutPinnedIdentityChoosesPIBThenSKR() {
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: nil,
            pinnedProtocolFingerprints: [],
            preferredTargetSuite: .xwing
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testStrictPreflightUnsignedLegacyKEMStillRequiresPIBBeforeSignedRefreshEvidence() {
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [.xwing],
            signedRefreshEvidence: nil,
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)],
            preferredTargetSuite: .xwing,
            requiresSignedRefreshEvidence: true
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testStrictPreflightOnlyProceedsAfterSignedLANRefreshEvidenceIsImported() async throws {
        let peerId = "id:mac-skr-chain"
        let now = Date()
        let signingKey = Curve25519.Signing.PrivateKey()
        let protocolPublicKey = signingKey.publicKey.rawRepresentation
        let protocolFingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .ed25519
        ).authoritativeFingerprint

        await KEMTrustStore.shared.clearForTesting()
        await KEMTrustStore.shared.upsert(
            deviceId: peerId,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0xA1, count: 1216)
                )
            ]
        )

        let unsignedEvidence = await KEMTrustStore.shared.signedRefreshEvidence(forAny: [peerId])
        let unsignedKeys = await P2PConnectionManager.trustedPeerKEMPublicKeysFromAllStores(forAny: [peerId])
        let unsignedAction = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: Set(unsignedKeys.keys),
            signedRefreshEvidence: unsignedEvidence,
            pinnedProtocolFingerprints: [protocolFingerprint],
            preferredTargetSuite: .xwing,
            requiresSignedRefreshEvidence: true
        )
        XCTAssertEqual(unsignedAction, .attemptOOBProtocolIdentityBindingThenRefresh)

        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-viewer",
            targetDeviceId: peerId,
            requesterProtocolIdentityFingerprint: String(repeating: "b", count: 64),
            targetProtocolIdentityFingerprint: protocolFingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            nonce: Data(repeating: 0x44, count: 24),
            sentAt: now
        )
        let unsignedPayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: peerId,
            aliases: [peerId, "bonjour:mac-skr-chain@local."],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: protocolFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x55, count: 1216)
                )
            ],
            keyId: "skr-chain-1",
            generation: 9,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            signature: Data()
        )
        let provider = ClassicSignatureProvider()
        let signature = try await provider.sign(
            unsignedPayload.signaturePreimage,
            key: .softwareKey(signingKey.rawRepresentation)
        )
        let signedPayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: unsignedPayload.deviceId,
            aliases: unsignedPayload.aliases,
            protocolSigningAlgorithm: unsignedPayload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: unsignedPayload.protocolIdentityPublicKey,
            protocolIdentityFingerprint: unsignedPayload.protocolIdentityFingerprint,
            kemPublicKeys: unsignedPayload.kemPublicKeys,
            keyId: unsignedPayload.keyId,
            generation: unsignedPayload.generation,
            sentAt: unsignedPayload.sentAt,
            expiresAt: unsignedPayload.expiresAt,
            requestNonce: unsignedPayload.requestNonce,
            requestHashHex: unsignedPayload.requestHashHex,
            signature: signature
        )

        XCTAssertNoThrow(try signedPayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [protocolFingerprint],
            minimumGeneration: nil
        ))
        let verifiedSignature = try await provider.verify(
            signedPayload.signaturePreimage,
            signature: signedPayload.signature,
            publicKey: protocolPublicKey
        )
        XCTAssertTrue(verifiedSignature)

        try await KEMTrustStore.shared.upsertSignedKEMRefresh(
            deviceIds: [peerId],
            payload: signedPayload,
            request: request,
            pinnedProtocolFingerprints: [protocolFingerprint],
            minimumGeneration: nil
        )

        let maybeSignedEvidence = await KEMTrustStore.shared.signedRefreshEvidence(forAny: [peerId])
        let signedEvidence = try XCTUnwrap(maybeSignedEvidence)
        XCTAssertEqual(signedEvidence.source, "signed_lan_kem_refresh")
        XCTAssertEqual(signedEvidence.keyId, "skr-chain-1")
        XCTAssertEqual(signedEvidence.generation, 9)
        XCTAssertEqual(signedEvidence.signingFingerprint, protocolFingerprint.lowercased())
        XCTAssertNotNil(signedEvidence.payloadHashHex)

        let signedKeys = await P2PConnectionManager.trustedPeerKEMPublicKeysFromAllStores(forAny: [peerId])
        let signedAction = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: Set(signedKeys.keys),
            signedRefreshEvidence: signedEvidence,
            pinnedProtocolFingerprints: [protocolFingerprint],
            preferredTargetSuite: .xwing,
            requiresSignedRefreshEvidence: true
        )
        XCTAssertEqual(signedAction, .proceed)

        await KEMTrustStore.shared.clearForTesting()
    }

    func testStrictPreflightSignedRefreshEvidenceAllowsProceed() {
        let evidence = KEMTrustStore.SignedRefreshEvidence(
            deviceId: "id:signed-refresh-peer",
            suiteWireIds: [CryptoSuite.xwing.wireId],
            source: "signed_lan_kem_refresh",
            keyId: "skr1-test",
            generation: 1,
            expiresAt: Date().addingTimeInterval(60),
            protocolIdentityFingerprint: String(repeating: "a", count: 64),
            signingFingerprint: String(repeating: "a", count: 64),
            payloadHashHex: String(repeating: "b", count: 64),
            updatedAt: Date()
        )
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: evidence,
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)],
            preferredTargetSuite: .xwing
        )

        XCTAssertEqual(action, .proceed)
    }

    func testStrictPreflightSignedEvidenceStillRequiresPinnedProtocolIdentity() {
        let evidence = KEMTrustStore.SignedRefreshEvidence(
            deviceId: "id:mac-skr-without-pin",
            suiteWireIds: [CryptoSuite.xwing.wireId],
            source: "signed_lan_kem_refresh",
            keyId: "skr1-test",
            generation: 1,
            expiresAt: Date().addingTimeInterval(60),
            protocolIdentityFingerprint: String(repeating: "a", count: 64),
            signingFingerprint: String(repeating: "a", count: 64),
            payloadHashHex: String(repeating: "b", count: 64),
            updatedAt: Date()
        )
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: evidence,
            pinnedProtocolFingerprints: [],
            preferredTargetSuite: .xwing
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testStrictPreflightSKRIdentityMismatchChoosesPIBThenSKR() {
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: nil,
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)],
            preferredTargetSuite: .xwing,
            signedRefreshFailureReason: "remote rejected SKR-1 stage=kem_refresh reasonCode=pinned_protocol_identity_mismatch_requires_oob"
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testStrictPreflightSKRRequesterNotPinnedChoosesPIBThenSKR() {
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: nil,
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)],
            preferredTargetSuite: .xwing,
            signedRefreshFailureReason: "remote rejected SKR-1 stage=kem_refresh reasonCode=requester_protocol_identity_not_pinned"
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testDiscoveredDeviceAddUsesDeviceConfirmationPairingInsteadOfDirectTrust() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/SettingsView.swift"
        )

        XCTAssertTrue(source.contains("Section(\"从已发现设备添加\")"))
        XCTAssertFalse(
            source.contains("store.trust(dev)"),
            "Bonjour discovery must not become a TOFU trust source; discovered devices must use the PIB-1 device confirmation path."
        )
        XCTAssertTrue(source.contains("startDeviceConfirmationPairing(dev)"))
        XCTAssertTrue(source.contains("P2PConnectionManager.instance.connect(to: device)"))
        XCTAssertTrue(source.contains("设备确认码配对"))
    }

    func testSettingsSecurityControlsDoNotExposeFakeRuntimeBindings() throws {
        let settingsSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/SettingsView.swift"
        )
        let contentSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/ContentView.swift"
        )

        XCTAssertFalse(settingsSource.contains(".constant(false)"))
        XCTAssertFalse(settingsSource.contains("Toggle(isOn: $settingsManager.requireBiometricAuth)"))
        XCTAssertFalse(settingsSource.contains("Toggle(isOn: $settingsManager.endToEndEncryption)"))
        XCTAssertFalse(settingsSource.contains("Image(systemName: \"checkmark.circle.fill\")\n                        .foregroundColor(.green)"))
        XCTAssertFalse(settingsSource.contains("try? await pqcManager.generateKeyPair()"))
        XCTAssertFalse(settingsSource.contains("try? await pqcManager.regenerateKeyPair()"))
        XCTAssertFalse(contentSource.contains(".sheet(\n            item: Binding(\n                get: { connectionManager.pendingPairingTrustRequest }"))
        XCTAssertTrue(contentSource.contains("PairingTrustPromptWindowPresenter"))
        XCTAssertTrue(contentSource.contains("Button(RuntimeLocalization.string(\"关闭\")) { onDecision(.reject) }"))
    }

    func testLegacyPQCVerificationCannotPersistTrustWithoutProtocolIdentityPin() throws {
        let pqcSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/PQCCryptoManager.swift"
        )
        let trustedStoreSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/TrustedDeviceStore.swift"
        )

        XCTAssertFalse(pqcSource.contains("TrustedDeviceStore.shared.trust(device)"))
        XCTAssertTrue(pqcSource.contains("pinnedFingerprints.count == 1"))
        XCTAssertTrue(pqcSource.contains("TrustedDeviceStore.shared.trustResolvedPeer"))
        XCTAssertFalse(pqcSource.contains("expected=\\(expected)"))
        XCTAssertFalse(pqcSource.contains("got=\\(code)"))
        XCTAssertFalse(
            trustedStoreSource.contains("guard !normalizedDeclaredDeviceId.isEmpty else {\n            trust(device)"),
            "trustResolvedPeer must not fall back to direct discovery trust when the authenticated declared device id is missing."
        )
    }

    func testCryptoKitErrorThreeIsTreatedAsStaleKEMCryptoFailure() {
        let error = NSError(
            domain: "CryptoKit.CryptoKitError",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed. (CryptoKit.CryptoKitError error 3.)"]
        )

        XCTAssertTrue(P2PConnectionManager.isLikelyStalePeerKEMCryptoFailure(error))
    }

    func testMessageBPayloadAuthenticationFailureIsTreatedAsStaleKEMCryptoFailure() {
        let error = HandshakeError.failed(
            .cryptoError(
                "messageBPayloadAuthenticationFailed suite=ML-KEM-768: The operation couldn’t be completed. (CryptoKit.CryptoKitError error 3.)"
            )
        )

        XCTAssertTrue(P2PConnectionManager.isLikelyStalePeerKEMCryptoFailure(error))
        XCTAssertEqual(
            P2PConnectionManager.localizedConnectionErrorMessage(error),
            "安全验证失败：解密认证失败（可能是对端 PQC KEM 公钥已变更或缓存失效）。当前已中止连接，不会降级或假装成功；请重新完成受信任设备验证后重试。"
        )
    }

    func testStaleKEMFailureEntersSignedLANRefreshInsteadOfUserRetry() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("recoverStalePeerKEMWithSignedLANRefresh"))
        XCTAssertTrue(source.contains("stage=stale-kem-refresh"))
        XCTAssertTrue(source.contains("failure=messageBPayloadAuthenticationFailed"))
        XCTAssertFalse(source.contains("请重试连接以触发 SKR-1 signed LAN KEM refresh"))
    }

    func testSignedLANRefreshRemoteFailureIsSurfacedWithReasonCode() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("case .kemRefreshFailure(let failure)"))
        XCTAssertTrue(source.contains("remote rejected SKR-1 stage="))
        XCTAssertTrue(source.contains("reasonCode=\\(failure.reasonCode)"))
    }

    func testSignedLANRefreshRequestBindsPolicyHashOnIOS() {
        let fingerprint = String(repeating: "a", count: 64)
        let nonce = Data(repeating: 0x44, count: 24)
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            nonce: nonce,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(request.policyHashHex, request.expectedPolicyHashHex)
        XCTAssertTrue(request.hasExpectedPolicyHash)
        XCTAssertTrue(request.hasRequesterProtocolIdentityFingerprint)
        let preimage = String(data: request.canonicalPreimage, encoding: .utf8) ?? ""
        XCTAssertTrue(preimage.contains("requesterProtocolIdentityFingerprint=\(fingerprint.lowercased())"))
        XCTAssertTrue(preimage.contains("policyRequirePQC=1"))
        XCTAssertTrue(preimage.contains("policyAllowClassicFallback=0"))
        XCTAssertTrue(preimage.contains("policyHashHex=\(request.expectedPolicyHashHex)"))

        let tamperedPolicyHash = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            policyHashHex: String(repeating: "0", count: 64),
            nonce: nonce,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(tamperedPolicyHash.hasExpectedPolicyHash)
        XCTAssertNotEqual(tamperedPolicyHash.canonicalRequestHashHex, request.canonicalRequestHashHex)

        let missingRequesterIdentity = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            nonce: nonce,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(missingRequesterIdentity.hasRequesterProtocolIdentityFingerprint)
    }

    func testSignedLANRefreshRequestCarriesRequesterIdentityAndVerifiesBeforeImport() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("localProtocolIdentityFingerprintForSignedLANRefresh"))
        XCTAssertTrue(source.contains("requesterProtocolIdentityFingerprint: requesterProtocolIdentityFingerprint"))
        guard let verifyRange = source.range(of: "let verified = try await signatureProvider.verify"),
              let upsertRange = source.range(of: "try await KEMTrustStore.shared.upsertSignedKEMRefresh") else {
            XCTFail("SKR-1 verify/upsert path not found")
            return
        }
        XCTAssertLessThan(verifyRange.lowerBound, upsertRange.lowerBound)
        XCTAssertTrue(source.contains("guard verified else"))
        XCTAssertTrue(source.contains("signature verification failed"))
    }

    func testSignedLANRefreshImportBindsOriginalRequestOnIOS() throws {
        let now = Date()
        let protocolPublicKey = Data(repeating: 0x33, count: 1184)
        let fingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeFingerprint
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            nonce: Data(repeating: 0x44, count: 24),
            sentAt: now
        )
        let payload = AppMessage.SignedKEMRefreshPayload(
            deviceId: "id:mac-1",
            aliases: ["id:mac-1"],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: fingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x55, count: 1216)
                )
            ],
            keyId: "skr-1",
            generation: 7,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            signature: Data(repeating: 0x99, count: 64)
        )
        let preimage = String(data: payload.signaturePreimage, encoding: .utf8) ?? ""
        XCTAssertTrue(preimage.contains("suiteNames=X-Wing"))
        XCTAssertTrue(preimage.contains("suiteWireIds=0x0001"))

        XCTAssertNoThrow(try payload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        ))

        let unrequestedSuitePayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: payload.deviceId,
            aliases: payload.aliases,
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: payload.protocolIdentityPublicKey,
            protocolIdentityFingerprint: payload.protocolIdentityFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
                    publicKey: Data(repeating: 0x66, count: 1184)
                )
            ],
            keyId: payload.keyId,
            generation: payload.generation,
            sentAt: payload.sentAt,
            expiresAt: payload.expiresAt,
            requestNonce: payload.requestNonce,
            requestHashHex: payload.requestHashHex,
            signature: payload.signature
        )
        XCTAssertThrowsError(try unrequestedSuitePayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(
                error as? AppMessage.KEMRefreshValidationError,
                .responseSuiteNotRequested(wireId: CryptoSuite.mlkem768MLDSA65.wireId)
            )
        }

        let otherProtocolPublicKey = Data(repeating: 0x34, count: 1184)
        let otherFingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: otherProtocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeFingerprint
        let unpinnedPayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: payload.deviceId,
            aliases: payload.aliases,
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: otherProtocolPublicKey,
            protocolIdentityFingerprint: otherFingerprint,
            kemPublicKeys: payload.kemPublicKeys,
            keyId: payload.keyId,
            generation: payload.generation,
            sentAt: payload.sentAt,
            expiresAt: payload.expiresAt,
            requestNonce: payload.requestNonce,
            requestHashHex: payload.requestHashHex,
            signature: payload.signature
        )
        XCTAssertThrowsError(try unpinnedPayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(
                error as? AppMessage.KEMRefreshValidationError,
                .pinnedProtocolIdentityMismatch(fingerprint: otherFingerprint.lowercased())
            )
        }

        let wrongHashPayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: payload.deviceId,
            aliases: payload.aliases,
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: payload.protocolIdentityPublicKey,
            protocolIdentityFingerprint: payload.protocolIdentityFingerprint,
            kemPublicKeys: payload.kemPublicKeys,
            keyId: payload.keyId,
            generation: payload.generation,
            sentAt: payload.sentAt,
            expiresAt: payload.expiresAt,
            requestNonce: payload.requestNonce,
            requestHashHex: String(repeating: "e", count: 64),
            signature: payload.signature
        )
        XCTAssertThrowsError(try wrongHashPayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .requestHashMismatch)
        }

        let wrongNoncePayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: payload.deviceId,
            aliases: payload.aliases,
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: payload.protocolIdentityPublicKey,
            protocolIdentityFingerprint: payload.protocolIdentityFingerprint,
            kemPublicKeys: payload.kemPublicKeys,
            keyId: payload.keyId,
            generation: payload.generation,
            sentAt: payload.sentAt,
            expiresAt: payload.expiresAt,
            requestNonce: Data(repeating: 0x45, count: 24),
            requestHashHex: payload.requestHashHex,
            signature: payload.signature
        )
        XCTAssertThrowsError(try wrongNoncePayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .requestNonceMismatch)
        }

        let wrongTargetPayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: "id:other-mac",
            aliases: ["bonjour:other-mac@local."],
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: payload.protocolIdentityPublicKey,
            protocolIdentityFingerprint: payload.protocolIdentityFingerprint,
            kemPublicKeys: payload.kemPublicKeys,
            keyId: payload.keyId,
            generation: payload.generation,
            sentAt: payload.sentAt,
            expiresAt: payload.expiresAt,
            requestNonce: payload.requestNonce,
            requestHashHex: payload.requestHashHex,
            signature: payload.signature
        )
        XCTAssertThrowsError(try wrongTargetPayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .targetDeviceIdMismatch)
        }

        let wrongPolicyRequest = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: request.requesterDeviceId,
            targetDeviceId: request.targetDeviceId,
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: request.requestedSuiteWireIds,
            policyHashHex: String(repeating: "0", count: 64),
            nonce: request.nonce,
            sentAt: request.sentAt
        )
        XCTAssertThrowsError(try payload.validatedForStrictPQCImport(
            request: wrongPolicyRequest,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .requestPolicyHashMismatch)
        }
    }

    func testSignedLANRefreshRejectsTamperedSignatureOnIOS() async throws {
        let now = Date()
        let signingKey = Curve25519.Signing.PrivateKey()
        let protocolPublicKey = signingKey.publicKey.rawRepresentation
        let protocolFingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .ed25519
        ).authoritativeFingerprint
        let unsigned = AppMessage.SignedKEMRefreshPayload(
            deviceId: "id:mac-1",
            aliases: ["id:mac-1", "bonjour:mac@local."],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: protocolFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x55, count: 1216)
                )
            ],
            keyId: "skr-1",
            generation: 7,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: Data(repeating: 0x44, count: 24),
            requestHashHex: String(repeating: "b", count: 64),
            signature: Data()
        )
        let provider = ClassicSignatureProvider()
        let signature = try await provider.sign(
            unsigned.signaturePreimage,
            key: .softwareKey(signingKey.rawRepresentation)
        )
        let signed = AppMessage.SignedKEMRefreshPayload(
            deviceId: unsigned.deviceId,
            aliases: unsigned.aliases,
            protocolSigningAlgorithm: unsigned.protocolSigningAlgorithm,
            protocolIdentityPublicKey: unsigned.protocolIdentityPublicKey,
            protocolIdentityFingerprint: unsigned.protocolIdentityFingerprint,
            kemPublicKeys: unsigned.kemPublicKeys,
            keyId: unsigned.keyId,
            generation: unsigned.generation,
            sentAt: unsigned.sentAt,
            expiresAt: unsigned.expiresAt,
            requestNonce: unsigned.requestNonce,
            requestHashHex: unsigned.requestHashHex,
            signature: signature
        )

        XCTAssertNoThrow(try signed.validatedForStrictPQCImport(
            now: now,
            pinnedProtocolFingerprints: [protocolFingerprint],
            minimumGeneration: 7
        ))
        let signedVerification = try await provider.verify(
            signed.signaturePreimage,
            signature: signed.signature,
            publicKey: protocolPublicKey
        )
        XCTAssertTrue(signedVerification)

        let tampered = AppMessage.SignedKEMRefreshPayload(
            deviceId: signed.deviceId,
            aliases: signed.aliases,
            protocolSigningAlgorithm: signed.protocolSigningAlgorithm,
            protocolIdentityPublicKey: signed.protocolIdentityPublicKey,
            protocolIdentityFingerprint: signed.protocolIdentityFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x56, count: 1216)
                )
            ],
            keyId: signed.keyId,
            generation: signed.generation,
            sentAt: signed.sentAt,
            expiresAt: signed.expiresAt,
            requestNonce: signed.requestNonce,
            requestHashHex: signed.requestHashHex,
            signature: signed.signature
        )
        let tamperedVerification = try await provider.verify(
            tampered.signaturePreimage,
            signature: tampered.signature,
            publicKey: protocolPublicKey
        )
        XCTAssertFalse(tamperedVerification)
    }

    func testNonAEADCryptoErrorDoesNotTriggerStaleKEMClearing() {
        let error = HandshakeError.failed(.cryptoError("CryptoKit.CryptoKitError error 0"))

        XCTAssertFalse(P2PConnectionManager.isLikelyStalePeerKEMCryptoFailure(error))
    }

    func testMissingPeerKEMIsProvisioningFailureNotStaleKEMClear() {
        let error = HandshakeError.failed(.missingPeerKEMPublicKey(suite: CryptoSuite.xwing.rawValue))

        XCTAssertFalse(P2PConnectionManager.isLikelyStalePeerKEMCryptoFailure(error))
        XCTAssertEqual(
            P2PConnectionManager.localizedConnectionErrorMessage(error),
            "缺少对端后量子密钥材料（X-Wing），无法建立 PQC 握手。当前已中止连接，不会降级或假装成功；请重新完成受信任设备验证后重试。"
        )
    }

    func testStrictPQCPreflightReadsExpandedKEMTrustAliases() async throws {
        let uuid = "11111111-1111-1111-1111-111111111111"
        let peerId = "id:\(uuid)"
        let alias = uuid
        let key = Data(repeating: 0xAB, count: 1_216)

        await KEMTrustStore.shared.clearForTesting()

        await KEMTrustStore.shared.upsert(
            deviceId: peerId,
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwing.wireId, publicKey: key)]
        )

        let merged = await P2PConnectionManager.trustedPeerKEMPublicKeysFromAllStores(forAny: [alias])
        XCTAssertEqual(merged[.xwing], key)

        await KEMTrustStore.shared.clearForTesting()
    }

    func testProtocolIdentityTrustStoreResolvesPinnedFingerprintDeviceIds() async throws {
        let peerId = "id:stable-p2p-mac"
        let fingerprint = String(repeating: "b", count: 64)

        await ProtocolIdentityTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.upsert(deviceId: peerId, fingerprints: [fingerprint])

        let deviceIds = await ProtocolIdentityTrustStore.shared.deviceIds(containingFingerprint: fingerprint)
        XCTAssertTrue(deviceIds.contains(peerId))
        XCTAssertTrue(deviceIds.contains("stable-p2p-mac"))
        let invalidFingerprintMatches = await ProtocolIdentityTrustStore.shared
            .deviceIds(containingFingerprint: String(repeating: "z", count: 64))
        XCTAssertTrue(invalidFingerprintMatches.isEmpty)

        await ProtocolIdentityTrustStore.shared.clearForTesting()
    }

    func testForgetClearsKEMAndProtocolIdentityCaches() async throws {
        let peerId = "id:forgotten-peer"
        let key = Data(repeating: 0xA1, count: 1_216)
        let fingerprint = String(repeating: "a", count: 64)
        let kemKeys = [KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwing.wireId, publicKey: key)]

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()

        await KEMTrustStore.shared.upsert(deviceId: peerId, kemPublicKeys: kemKeys)
        await ProtocolIdentityTrustStore.shared.upsert(deviceId: peerId, fingerprints: [fingerprint])

        await P2PConnectionManager.instance.clearTrustMaterialForForgottenDevice(deviceIds: [peerId])

        let clearedKEMKeys = await KEMTrustStore.shared.kemPublicKeys(forAny: [peerId])
        let clearedFingerprints = await ProtocolIdentityTrustStore.shared.trustedFingerprints(forAny: [peerId])
        XCTAssertTrue(clearedKEMKeys.isEmpty)
        XCTAssertTrue(clearedFingerprints.isEmpty)

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()
    }

    func testFullForgetDoesNotAllowSKRImportWithoutPinnedProtocolIdentity() async throws {
        let peerId = "id:forgotten-refresh-peer"
        let oldKEM = Data(repeating: 0xA1, count: 1216)
        let oldFingerprint = String(repeating: "a", count: 64)
        let protocolPublicKey = Data(repeating: 0x33, count: 1184)
        let protocolFingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeFingerprint
        let now = Date()

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()

        await KEMTrustStore.shared.upsert(
            deviceId: peerId,
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwingMLDSA.wireId, publicKey: oldKEM)]
        )
        await ProtocolIdentityTrustStore.shared.upsert(deviceId: peerId, fingerprints: [oldFingerprint])

        await P2PConnectionManager.instance.clearTrustMaterialForForgottenDevice(deviceIds: [peerId])

        let keysAfterForget = await KEMTrustStore.shared.kemPublicKeys(forAny: [peerId])
        let fingerprintsAfterForget = await ProtocolIdentityTrustStore.shared.trustedFingerprints(forAny: [peerId])
        XCTAssertTrue(keysAfterForget.isEmpty)
        XCTAssertTrue(fingerprintsAfterForget.isEmpty)

        let payload = AppMessage.SignedKEMRefreshPayload(
            deviceId: peerId,
            aliases: [peerId, "bonjour:forgotten-refresh-peer@local."],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: protocolFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x55, count: 1216)
                )
            ],
            keyId: "skr-1-after-full-forget",
            generation: 8,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: Data(repeating: 0x44, count: 24),
            requestHashHex: String(repeating: "b", count: 64),
            signature: Data(repeating: 0x99, count: 64)
        )
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-test-requester",
            targetDeviceId: peerId,
            requesterProtocolIdentityFingerprint: protocolFingerprint,
            targetProtocolIdentityFingerprint: protocolFingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            nonce: payload.requestNonce
        )

        do {
            try await KEMTrustStore.shared.upsertSignedKEMRefresh(
                deviceIds: [peerId],
                payload: payload,
                request: request,
                pinnedProtocolFingerprints: [],
                minimumGeneration: nil
            )
            XCTFail("Full forget must not allow SKR-1 import without pinned protocol identity")
        } catch {
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .missingPinnedProtocolIdentity)
        }

        let keysAfterRejectedImport = await KEMTrustStore.shared.kemPublicKeys(forAny: [peerId])
        let evidenceAfterRejectedImport = await KEMTrustStore.shared.signedRefreshEvidence(forAny: [peerId])
        XCTAssertTrue(keysAfterRejectedImport.isEmpty)
        XCTAssertNil(evidenceAfterRejectedImport)

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()
    }

    func testRepairP2PTrustClearsOnlyKEMAndPreservesPinnedProtocolIdentity() async throws {
        let peerId = "id:repair-peer"
        let key = Data(repeating: 0xA1, count: 1_216)
        let fingerprint = String(repeating: "b", count: 64)
        let kemKeys = [KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwing.wireId, publicKey: key)]

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()

        await KEMTrustStore.shared.upsert(deviceId: peerId, kemPublicKeys: kemKeys)
        await ProtocolIdentityTrustStore.shared.upsert(deviceId: peerId, fingerprints: [fingerprint])

        await P2PConnectionManager.instance.repairP2PTrustForTrustedDevice(deviceIds: [peerId])

        let clearedKEMKeys = await KEMTrustStore.shared.kemPublicKeys(forAny: [peerId])
        let preservedFingerprints = await ProtocolIdentityTrustStore.shared.trustedFingerprints(forAny: [peerId])
        XCTAssertTrue(clearedKEMKeys.isEmpty)
        XCTAssertEqual(preservedFingerprints, [fingerprint])

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()
    }

    func testStrictPQCPreflightSurfacesMissingPinnedIdentityRequiresOOB() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("missing_pinned_identity_requires_oob"))
        XCTAssertTrue(source.contains("short_authentication_string"))
        XCTAssertTrue(source.contains("双端显示同一设备确认码"))
    }

    func testStrictPQCUsesPIB1BeforeSKR1WhenProtocolIdentityNeedsOOB() throws {
        let managerSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let policySource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager+StrictPQCTrustPolicy.swift"
        )
        let source = managerSource + "\n" + policySource

        XCTAssertTrue(source.contains("attemptOOBProtocolIdentityBinding"))
        XCTAssertTrue(source.contains("AppMessage.protocolIdentityBindingRequest"))
        XCTAssertTrue(source.contains("shortAuthenticationCode"))
        XCTAssertTrue(source.contains("installOOBProtocolIdentityBinding"))
        XCTAssertTrue(source.contains("PIB-1 -> SKR-1 recovery completed"))
        XCTAssertTrue(source.contains("requester_protocol_identity_not_pinned"))
        XCTAssertTrue(source.contains("signedRefreshFailureReason = Self.smokeSanitize(error.localizedDescription)"))
        XCTAssertFalse(source.contains("signedRefreshFailureReason = \"preflight-kem-refresh-failed\""))
        XCTAssertFalse(source.contains("policyAllowClassicFallback: true"))
    }

    func testTrustedPeerKEMRequiresStableProtocolIdentityCandidate() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private func trustedPeerKEM(for device: DiscoveredDevice)"))
        let end = try XCTUnwrap(source.range(of: "private func peerKEMLookupCandidates", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("guard let stablePeerId = stableProtocolIdentityCandidate(from: candidates)"))
        XCTAssertTrue(body.contains("missing stable protocol identity"))
        XCTAssertTrue(body.contains("refusing endpoint alias target"))
        XCTAssertTrue(body.contains("return nil"))
        XCTAssertTrue(body.contains("return (stablePeerId, keys)"))
        XCTAssertFalse(body.contains("?? candidates.first ?? device.id"))
    }

    func testStableProtocolIdentityCandidateResolvesEndpointAliasesBeforeTrustMaterial() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(
            source.range(of: "private func stableProtocolIdentityCandidate(from candidates: [String])"))
        let end = try XCTUnwrap(
            source.range(
                of: "private func strictInboundHandshakeTrustContext",
                range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("PeerIdentityAliasResolver.persistentDeviceId(from: normalized)"))
        XCTAssertTrue(body.contains("peerAliasToCanonicalDeviceId[normalized]"))
        XCTAssertTrue(body.contains("TrustedDeviceStore.shared.uniqueCanonicalTrustedDeviceId(for: normalized)"))
        XCTAssertTrue(body.contains("lastKnownDevices[normalized]"))
        XCTAssertTrue(body.contains("PeerIdentityAliasResolver.aliasKeys(for: knownDevice)"))
        XCTAssertTrue(body.contains("discoveryManager.discoveredDevices.first"))
        XCTAssertTrue(body.contains("visited.insert(normalized).inserted"))
        XCTAssertFalse(body.contains("return candidates.first"))

        let connectStart = try XCTUnwrap(
            source.range(of: "public func connect(to device: DiscoveredDevice) async throws"))
        let connectEnd = try XCTUnwrap(
            source.range(
                of: "public func disconnect(from device: DiscoveredDevice) async -> Bool",
                range: connectStart.lowerBound..<source.endIndex))
        let connectBody = String(source[connectStart.lowerBound..<connectEnd.lowerBound])
        XCTAssertTrue(connectBody.contains("let stableProtocolPeerId = stableProtocolIdentityCandidate("))
        XCTAssertTrue(connectBody.contains("primaryPeerId: preferredTrustedPeerId ?? stableProtocolPeerId ?? resolvedTargetDevice.id"))
    }

    func testStrictInboundHandshakeUsesMessageASOAStableIdentityCandidates() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let helperStart = try XCTUnwrap(
            source.range(of: "private func stableProtocolIdentityCandidates(from messageA: HandshakeMessageA?)"))
        let helperEnd = try XCTUnwrap(
            source.range(
                of: "private func strictInboundHandshakeTrustContext",
                range: helperStart.lowerBound..<source.endIndex))
        let helperBody = String(source[helperStart.lowerBound..<helperEnd.lowerBound])

        XCTAssertTrue(helperBody.contains("messageA.soaExtension"))
        XCTAssertTrue(helperBody.contains("soa.initiatorPeerId"))
        XCTAssertTrue(helperBody.contains("soaPeerIdBytes(for: normalizedStablePeerId)"))
        XCTAssertTrue(helperBody.contains("TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: fingerprint)"))
        XCTAssertTrue(helperBody.contains("ProtocolIdentityTrustStore.shared.deviceIds(containingFingerprint: fingerprint)"))
        XCTAssertTrue(helperBody.contains("TrustedDeviceStore.shared.trustedDevices"))
        XCTAssertTrue(helperBody.contains("PeerIdentityAliasResolver.aliasKeys(for: device)"))
        XCTAssertTrue(helperBody.contains("lastAcceptedPairingIdentityDeviceIdByPeerId"))

        let trustStart = try XCTUnwrap(
            source.range(
                of: "private func strictInboundHandshakeTrustContext",
                range: helperEnd.lowerBound..<source.endIndex))
        let trustEnd = try XCTUnwrap(
            source.range(
                of: "private func preferredStrictPQCHandshakeTargetSuite",
                range: trustStart.lowerBound..<source.endIndex))
        let trustBody = String(source[trustStart.lowerBound..<trustEnd.lowerBound])

        XCTAssertTrue(trustBody.contains("messageA: HandshakeMessageA? = nil"))
        XCTAssertTrue(trustBody.contains("let messageAStableCandidates = await stableProtocolIdentityCandidates(from: messageA)"))
        XCTAssertTrue(trustBody.contains("reason=ambiguous_message_a_soa_identity"))
        XCTAssertTrue(trustBody.contains("let candidates = messageAStableCandidates + [peerId, runtimePeerId, presentationPeerId, canonicalPeerId]"))
        XCTAssertTrue(trustBody.contains("requirePinnedProtocolIdentity: true"))
        XCTAssertTrue(trustBody.contains("resolved stable peer from MessageA SOA"))

        let inboundStart = try XCTUnwrap(
            source.range(of: "private func ensureInboundHandshakeDriverIfNeeded("))
        let inboundEnd = try XCTUnwrap(
            source.range(of: "private func processHandshakeFrame(", range: inboundStart.lowerBound..<source.endIndex))
        let inboundBody = String(source[inboundStart.lowerBound..<inboundEnd.lowerBound])
        XCTAssertTrue(inboundBody.contains("stage: \"inbound-handshake\""))
        XCTAssertTrue(inboundBody.contains("messageA: messageA"))

        let rekeyStart = try XCTUnwrap(
            source.range(of: "private func ensureInboundRekeyDriverIfNeeded("))
        let rekeyEnd = try XCTUnwrap(
            source.range(of: "private func isLikelyHandshakeControlPacket", range: rekeyStart.lowerBound..<source.endIndex))
        let rekeyBody = String(source[rekeyStart.lowerBound..<rekeyEnd.lowerBound])
        XCTAssertTrue(rekeyBody.contains("stage: \"inbound-rekey\""))
        XCTAssertTrue(rekeyBody.contains("messageA: messageA"))
    }

    func testStrictPQCTrustProviderDoesNotUseEndpointAliasesAsPinMaterial() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private struct P2PStoredHandshakeTrustProvider"))
        let end = try XCTUnwrap(
            source.range(
                of: "/// P2P 连接管理器",
                range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("!PeerIdentityAliasResolver.isEndpointAlias(trimmed)"))
        XCTAssertTrue(body.contains("where !PeerIdentityAliasResolver.isEndpointAlias(alias)"))
        XCTAssertTrue(body.contains("requirePinnedProtocolIdentity"))
    }

    func testPIB1RequestRequiresStableProtocolIdentityTarget() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private func attemptOOBProtocolIdentityBinding("))
        let end = try XCTUnwrap(source.range(of: "private func localProtocolIdentityProofForProtocolBinding", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("guard let targetProtocolDeviceId = stableProtocolIdentityCandidate(from: candidates)"))
        XCTAssertTrue(body.contains("missing stable protocol identity target"))
        XCTAssertTrue(body.contains("refusing endpoint alias target"))
        XCTAssertTrue(body.contains("targetDeviceId: targetProtocolDeviceId"))
        XCTAssertFalse(body.contains("targetDeviceId: candidates.first ?? device.id"))
    }

    func testPIB1ImporterUsesExistingProtocolIdentityPinAfterVerifiedBinding() {
        let fingerprint = String(repeating: "a", count: 64)

        XCTAssertEqual(
            P2PConnectionManager.protocolIdentityBindingStoredPolicyAction(
                pairingPolicyByPeerId: [:],
                policyCandidates: ["id:mac"],
                trustedProtocolFingerprints: [fingerprint],
                payloadFingerprint: fingerprint
            ),
            .approve(operatorLabel: "stored-protocol-identity")
        )
        XCTAssertEqual(
            P2PConnectionManager.protocolIdentityBindingStoredPolicyAction(
                pairingPolicyByPeerId: ["id:mac": P2PConnectionManager.PairingTrustDecision.reject.rawValue],
                policyCandidates: ["id:mac"],
                trustedProtocolFingerprints: [],
                payloadFingerprint: fingerprint
            ),
            .reject
        )
        XCTAssertNil(
            P2PConnectionManager.protocolIdentityBindingStoredPolicyAction(
                pairingPolicyByPeerId: ["id:other": P2PConnectionManager.PairingTrustDecision.alwaysAllow.rawValue],
                policyCandidates: ["id:mac"],
                trustedProtocolFingerprints: [],
                payloadFingerprint: fingerprint
            )
        )
        XCTAssertNil(
            P2PConnectionManager.protocolIdentityBindingStoredPolicyAction(
                pairingPolicyByPeerId: ["id:mac": P2PConnectionManager.PairingTrustDecision.alwaysAllow.rawValue],
                policyCandidates: ["id:mac"],
                trustedProtocolFingerprints: [],
                payloadFingerprint: fingerprint
            )
        )
    }

    func testPIB1PolicyCandidatesIncludeDevicePayloadAliasesWithoutDuplicates() {
        let payload = AppMessage.SignedProtocolIdentityBindingPayload(
            deviceId: "id:payload-device",
            aliases: ["bonjour:Bill-iPad@local.", "id:mac"],
            protocolSigningAlgorithm: "ml-dsa-65",
            protocolIdentityPublicKey: Data([1, 2, 3]),
            protocolIdentityFingerprint: String(repeating: "b", count: 64),
            expiresAt: Date().addingTimeInterval(60),
            requestNonce: Data([4, 5, 6]),
            signature: Data([7, 8, 9])
        )
        let device = DiscoveredDevice(
            id: "host:10.0.0.2",
            name: "Bill iPad",
            modelName: "iPad",
            platform: .iPadOS,
            osVersion: "26.5",
            ipAddress: "10.0.0.2"
        )

        let policyCandidates = P2PConnectionManager.protocolIdentityBindingPolicyCandidates(
            for: device,
            candidates: [" id:mac ", "id:mac"],
            payload: payload
        )

        XCTAssertEqual(policyCandidates.first, "id:mac")
        XCTAssertTrue(policyCandidates.contains("host:10.0.0.2"))
        XCTAssertTrue(policyCandidates.contains("id:payload-device"))
        XCTAssertTrue(policyCandidates.contains("bonjour:Bill-iPad@local."))
        XCTAssertEqual(policyCandidates.filter { $0 == "id:mac" }.count, 1)
    }

    func testPIB1ImporterStoredPolicyPathIsNotSmokeFallback() throws {
        let managerSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let policySource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager+StrictPQCTrustPolicy.swift"
        )
        let source = managerSource + "\n" + policySource

        XCTAssertTrue(source.contains("protocolIdentityBindingStoredPolicyAction"))
        XCTAssertTrue(source.contains("ProtocolIdentityTrustStore.shared"))
        XCTAssertTrue(source.contains("TrustedDeviceStore.shared.currentPathFingerprints"))
        XCTAssertTrue(source.contains("operator=\\(operatorLabel)"))
        XCTAssertTrue(source.contains("clearExisting: false"))
        XCTAssertTrue(source.contains("stored-policy"))
        XCTAssertTrue(source.contains("stored-protocol-identity"))
        XCTAssertFalse(source.contains("return .approve(operatorLabel: \"stored-policy\")"))
        XCTAssertTrue(source.contains("SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING"))
        XCTAssertTrue(source.range(of: "protocolIdentityBindingStoredPolicyAction")!.lowerBound < source.range(of: "SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING")!.lowerBound)
    }

    func testSKR1RefreshPrefersDirectLANEndpointBeforeBonjourService() throws {
        let managerSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let endpointPolicySource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionEndpointPolicy.swift"
        )
        let source = managerSource + "\n" + endpointPolicySource
        let skrStart = try XCTUnwrap(managerSource.range(of: "private func attemptSignedLANKEMRefresh("))
        let requestLine = try XCTUnwrap(managerSource.range(of: "let requestLine =", range: skrStart.lowerBound..<managerSource.endIndex))
        let skrBody = String(managerSource[skrStart.lowerBound..<requestLine.lowerBound])

        XCTAssertTrue(skrBody.contains("connectionEndpointCandidates(for: device, preferDirectHostPort: true)"))
        XCTAssertTrue(skrBody.contains("let routeCandidates = connectionEndpointCandidates(for: device, preferDirectHostPort: true)"))
        XCTAssertTrue(skrBody.contains("Self.signedLANRefreshEndpointClass($0) == \"direct-host\""))
        XCTAssertTrue(skrBody.contains("throw signedLANRefreshFailure(\"missing direct LAN endpoint candidate\")"))
        XCTAssertTrue(skrBody.contains("endpointClass == \"direct-host\" || endpointClass == \"bonjour-service\""))
        XCTAssertTrue(source.contains("classicFallbackSuppressed=1"))
        XCTAssertTrue(source.contains("serviceFallbackCandidates=\\(serviceFallbackCandidateCount)"))
        XCTAssertTrue(source.contains("bootstrap control connection failed:"))
        XCTAssertFalse(skrBody.contains("establishReadyConnectionWithMetrics(to: routeCandidates"))
        XCTAssertTrue(source.contains("preferDirectHostPort: Bool = false"))
        XCTAssertTrue(source.contains("let prefersBonjour = !preferDirectHostPort &&"))
        XCTAssertTrue(source.contains("if (preferDirectHostPort || !prefersBonjour),"))
        XCTAssertTrue(source.contains("selectedEndpointClass=\\(selectedEndpointClass)"))
        XCTAssertTrue(source.contains("selectedEndpointDirect=\\(selectedEndpointDirect ? 1 : 0)"))
        XCTAssertTrue(source.contains("selectedEndpointPeerToPeer=\\(connectionResult.selectedEndpointPeerToPeer ? 1 : 0)"))
        XCTAssertTrue(source.contains("directHostCandidate=\\(directHostCandidate ? 1 : 0)"))
        XCTAssertTrue(source.contains("private static func signedLANRefreshEndpointClass"))
        XCTAssertTrue(source.contains("private func makeConnectionParameters(for endpoint: NWEndpoint) -> NWParameters"))
        XCTAssertTrue(source.contains("parameters.includePeerToPeer = Self.shouldIncludePeerToPeer(for: endpoint)"))
        XCTAssertTrue(source.contains("private static func shouldIncludePeerToPeer(for endpoint: NWEndpoint) -> Bool"))
        XCTAssertTrue(source.contains("ConnectableAddressCanonicalizer.prefersPeerToPeer(for: String(describing: host))"))
    }

    func testPIB1ApprovalTimeoutIsBoundedAndConfigurableForSmoke() throws {
        let source = try [
            readRepositorySource(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
            ),
            readRepositorySource(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager+StrictPQCTrustPolicy.swift"
            )
        ].joined(separator: "\n")

        XCTAssertTrue(source.contains("SKYBRIDGE_PIB_APPROVAL_TIMEOUT_SECONDS"))
        XCTAssertTrue(source.contains("return min(max(value, 30), 300)"))
        XCTAssertTrue(source.contains("return 180"))
        XCTAssertTrue(source.contains("protocolIdentityBindingResponseTimeoutSeconds"))
        XCTAssertTrue(source.contains("Double(protocolIdentityBindingApprovalTimeoutSeconds() + 15)"))
        XCTAssertTrue(source.contains("responseTimeoutSeconds=\\(Int(responseTimeoutSeconds))"))
        XCTAssertTrue(source.contains("case timedOut"))
        XCTAssertTrue(source.contains("operator approval timed out for PIB-1 verification code"))
        XCTAssertTrue(source.contains("identity-oob>awaiting-approval"))
        XCTAssertTrue(source.contains("lifecycle=identity-oob>timeout"))
        XCTAssertTrue(source.contains("timeoutSeconds=\\(approvalTimeoutSeconds)"))
        XCTAssertTrue(source.contains("let policyCandidates = Self.protocolIdentityBindingPolicyCandidates"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "candidates: policyCandidates").count - 1, 3)
    }

    func testPIB1StatusLinesRedactVerificationSecrets() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("protocolIdentityLogRedaction"))
        XCTAssertTrue(source.contains("code=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(source.contains("fingerprint=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(
            source.contains("verificationCode: verificationCode"),
            "The operator-facing pending approval state must keep the SAS even though logs redact it."
        )

        [
            "code=\\(code)",
            "code=\\(verificationCode)",
            "code=\\(context.verificationCode)",
            "fingerprint=\\(validated.protocolIdentityFingerprint)",
            "fingerprint=\\(payload.protocolIdentityFingerprint)",
            "fingerprint=\\(context.payload.protocolIdentityFingerprint)",
            "fingerprint=\\(context.requesterProtocolIdentityFingerprint)",
            "fingerprint=\\(requesterFingerprint)",
            "fingerprint=\\(authority.protocolPublicKeyFingerprint)",
            "PIB-1 protocol identity binding served: requester=\\(request.requesterDeviceId)",
            "PIB-1 protocol identity binding rejected: requester=\\(request.requesterDeviceId)",
            "PIB-1 requester protocol identity awaiting operator approval: requester=\\(stableRequesterId)",
            "deviceId=\\(payload.deviceId)"
        ].forEach { forbidden in
            XCTAssertFalse(
                source.contains(forbidden),
                "PIB-1 status/log lines must not persist raw protocol identity secrets: \(forbidden)"
            )
        }
    }

    func testSKR1InboundStatusLinesRedactRequestIdentifiersAndFailureReasons() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private func makeInboundBootstrapControlResponse"))
        let end = try XCTUnwrap(
            source.range(
                of: "private func makeInboundSignedKEMRefreshPayload",
                range: start.lowerBound..<source.endIndex
            )
        )
        let reviewedStatusBuilder = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(reviewedStatusBuilder.contains("SKR-1 signed LAN KEM refresh served"))
        XCTAssertTrue(reviewedStatusBuilder.contains("SKR-1 signed LAN KEM refresh rejected"))
        XCTAssertTrue(reviewedStatusBuilder.contains("reasonCode: Self.signedKEMRefreshFailureCode(for: error)"))
        XCTAssertTrue(reviewedStatusBuilder.contains("reason: error.localizedDescription"))
        XCTAssertTrue(reviewedStatusBuilder.contains("reason=%@ responderLatencyMs"))
        XCTAssertTrue(reviewedStatusBuilder.contains("requestHashHex: request.canonicalRequestHashHex"))
        XCTAssertTrue(reviewedStatusBuilder.contains("requesterDeviceId: request.requesterDeviceId"))
        XCTAssertTrue(reviewedStatusBuilder.contains("targetDeviceId: request.targetDeviceId"))
        XCTAssertTrue(reviewedStatusBuilder.contains("""
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
"""))
        XCTAssertTrue(reviewedStatusBuilder.contains("""
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
                    failure.reasonCode,
                    Self.protocolIdentityLogRedaction,
"""))

        [
            "payload.keyId,",
            "\n                    error.localizedDescription,\n"
        ].forEach { forbidden in
            XCTAssertFalse(
                reviewedStatusBuilder.contains(forbidden),
                "SKR-1 inbound status/failure paths must not expose raw request identifiers or local error details: \(forbidden)"
            )
        }
    }

    func testPairingIdentityExchangeDiagnosticsRedactStableIdentifiersAndErrors() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "public func resolvePairingTrustRequest"))
        let end = try XCTUnwrap(
            source.range(
                of: "public func waitForPairingIdentityExchangeActivity",
                range: start.lowerBound..<source.endIndex
            )
        )
        let reviewedPairingDiagnostics = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(source.contains("diagnosticErrorSummary(_ error: Error)"))
        XCTAssertTrue(source.contains("error_domain=\\(nsError.domain) code=\\(nsError.code)"))
        XCTAssertTrue(reviewedPairingDiagnostics.contains("peer=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(reviewedPairingDiagnostics.contains("declaredDeviceId=\\(Self.protocolIdentityLogRedaction)"))

        [
            "Pairing/trust request rejected: peer=\\(peerId)",
            "Pairing/trust request timed out: peer=\\(peerId)",
            "Pairing/trust request auto-rejected: peer=\\(peerId)",
            "UI prompt already pending; ignoring duplicate. peer=\\(peerId)",
            "忽略无效 pairingIdentityExchange: peer=\\(runtimePeerId)",
            "已保存对端 KEM 公钥：peer=\\(peerId) declaredDeviceId=\\(declaredDeviceId)",
            "已加入受信任设备：\\(device.name) peerId=\\(peerId)",
            "pairingIdentityExchange replied to peer=\\(peerId)",
            "pairingIdentityExchange reply failed (ignored): \\(error.localizedDescription)",
            "cleared stale rekey marker before pairingIdentityExchange: peer=\\(deviceId)",
            "pairingIdentityExchange delayed during active rekey: peer=\\(deviceId)",
            "pairingIdentityExchange sent: peer=\\(deviceId)"
        ].forEach { forbidden in
            XCTAssertFalse(
                reviewedPairingDiagnostics.contains(forbidden),
                "pairingIdentityExchange diagnostics must not expose stable identifiers or raw local errors: \(forbidden)"
            )
        }

        XCTAssertTrue(
            reviewedPairingDiagnostics.contains("deviceId: localId"),
            "Protocol payloads must keep the raw local device id; redaction is limited to diagnostics."
        )
        XCTAssertTrue(
            reviewedPairingDiagnostics.contains("await KEMTrustStore.shared.upsert(deviceId: declaredDeviceId"),
            "Trust/KEM storage keys must remain raw and deterministic."
        )
    }

    func testP2PDiagnosticTraceRedactsRuntimeIdentifiersAndEndpointDetails() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let inboundStart = try XCTUnwrap(source.range(of: "private func handleIncomingConnection"))
        let inboundEnd = try XCTUnwrap(
            source.range(
                of: "private func isLikelyHandshakeControlPacket",
                range: inboundStart.lowerBound..<source.endIndex
            )
        )
        let inboundDiagnostics = String(source[inboundStart.lowerBound..<inboundEnd.lowerBound])

        XCTAssertTrue(source.contains("diagnosticConnectionState(_ state: NWConnection.State)"))
        XCTAssertTrue(source.contains("diagnosticHandshakeFailureCode(_ reason: HandshakeFailureReason)"))
        XCTAssertTrue(inboundDiagnostics.contains("p2p-inbound handle-start peer=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(inboundDiagnostics.contains("p2p-inbound strict-trust-ready peer=\\(Self.protocolIdentityLogRedaction) stable=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(inboundDiagnostics.contains("p2p-inbound handshake-failed peer=\\(Self.protocolIdentityLogRedaction) reason=\\(Self.diagnosticHandshakeFailureCode(reason))"))
        XCTAssertTrue(inboundDiagnostics.contains("error=\\(Self.diagnosticErrorSummary(error))"))

        [
            "Self.smokeSanitize(peerId)",
            "Self.smokeSanitize(canonicalPeerId)",
            "Self.smokeSanitize(context.stablePeerId)",
            "peer=\\(peerId)",
            "处理入站连接: \\(peerId)",
            "等待来自 \\(canonicalPeerId)",
            "from \\(peerId)",
            "header=0x\\(headerHex)",
            "String(describing: reason)",
            "error=\\(Self.smokeSanitize(error.localizedDescription))",
            "error=\\(Self.smokeSanitize(error2.localizedDescription))"
        ].forEach { forbidden in
            XCTAssertFalse(
                inboundDiagnostics.contains(forbidden),
                "P2P inbound trace/log diagnostics must redact runtime identifiers and raw local details: \(forbidden)"
            )
        }

        let endpointStart = try XCTUnwrap(source.range(of: "private func establishReadyConnectionWithMetrics"))
        let endpointEnd = try XCTUnwrap(
            source.range(
                of: "private static func attemptDurationJitterMs",
                range: endpointStart.lowerBound..<source.endIndex
            )
        )
        let endpointDiagnostics = String(source[endpointStart.lowerBound..<endpointEnd.lowerBound])
        XCTAssertTrue(endpointDiagnostics.contains("endpoint=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertFalse(endpointDiagnostics.contains("endpointDescription"))
        XCTAssertFalse(endpointDiagnostics.contains("String(describing: endpoint)"))
        XCTAssertFalse(endpointDiagnostics.contains("\\(device.name) endpoint="))

        let stateStart = try XCTUnwrap(source.range(of: "private func handleConnectionStateChange"))
        let stateEnd = try XCTUnwrap(
            source.range(
                of: "private func scheduleReconnectIfNeeded",
                range: stateStart.lowerBound..<source.endIndex
            )
        )
        let stateDiagnostics = String(source[stateStart.lowerBound..<stateEnd.lowerBound])
        XCTAssertTrue(stateDiagnostics.contains("state=\\(Self.diagnosticConnectionState(state))"))
        XCTAssertFalse(stateDiagnostics.contains("String(describing: state)"))
        XCTAssertFalse(stateDiagnostics.contains("effectiveDevice.name"))
        XCTAssertFalse(stateDiagnostics.contains("runtimePeerId)) state="))
    }

    func testStrictPQCFailureStatusLinesRedactPeerIdentitySecrets() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let strictTrustStart = try XCTUnwrap(
            source.range(of: "private func strictInboundHandshakeTrustContext")
        )
        let strictTrustEnd = try XCTUnwrap(
            source.range(
                of: "private func preferredStrictPQCHandshakeTargetSuite",
                range: strictTrustStart.lowerBound..<source.endIndex
            )
        )
        let oobStart = try XCTUnwrap(
            source.range(of: "private func attemptOOBProtocolIdentityBinding(")
        )
        let oobEnd = try XCTUnwrap(
            source.range(
                of: "private func requestOOBProtocolIdentityApproval",
                range: oobStart.lowerBound..<source.endIndex
            )
        )
        let reviewedFailurePaths = String(source[strictTrustStart.lowerBound..<strictTrustEnd.lowerBound])
            + "\n"
            + String(source[oobStart.lowerBound..<oobEnd.lowerBound])

        XCTAssertTrue(reviewedFailurePaths.contains("reason=ambiguous_message_a_soa_identity"))
        XCTAssertTrue(reviewedFailurePaths.contains("reason=missing_stable_protocol_identity"))
        XCTAssertTrue(reviewedFailurePaths.contains("reason=missing_pinned_protocol_identity"))
        XCTAssertTrue(reviewedFailurePaths.contains("reasonCode=\\(failure.reasonCode) reason=redacted"))
        XCTAssertTrue(reviewedFailurePaths.contains("matchCount=\\(messageAStableCandidates.count)"))

        [
            "peer=\\(peerId)",
            "stablePeer=\\(stablePeerId)",
            "matches=\\(messageAStableCandidates.joined",
            "reason=\\(failure.reason)",
            "reason=\\(error.localizedDescription)"
        ].forEach { forbidden in
            XCTAssertFalse(
                reviewedFailurePaths.contains(forbidden),
                "Strict PQC/PIB failure status lines must not persist raw peer ids or remote reason text: \(forbidden)"
            )
        }
    }

    func testIOSBonjourDiscoveryDoesNotAcceptKEMFromTXT() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
        )

        let createStart = try XCTUnwrap(
            source.range(of: "private func createDevice(from result: NWBrowser.Result")
        )
        let createEnd = try XCTUnwrap(
            source.range(
                of: "private func isSelfDevice",
                range: createStart.upperBound..<source.endIndex
            )
        )
        let createDeviceSlice = source[createStart.lowerBound..<createEnd.lowerBound]
        XCTAssertTrue(createDeviceSlice.contains("publicKey: nil"))
        XCTAssertFalse(createDeviceSlice.localizedCaseInsensitiveContains("KEMTrustStore"))
        XCTAssertFalse(createDeviceSlice.localizedCaseInsensitiveContains("PeerKEMBootstrapStore"))
        XCTAssertFalse(createDeviceSlice.localizedCaseInsensitiveContains("kemPublic"))
        XCTAssertFalse(createDeviceSlice.contains("KEMPublicKeyInfo"))
        XCTAssertTrue(source.contains("record[\"kemRefreshVersion\"] = \"1\""))

        let dictionaryStart = try XCTUnwrap(source.range(of: "extension NWTXTRecord"))
        let dictionarySlice = source[dictionaryStart.lowerBound..<source.endIndex]
        XCTAssertTrue(dictionarySlice.contains("\"kemRefreshVersion\""))
        XCTAssertTrue(dictionarySlice.contains("\"kemKeyDigest\""))
        XCTAssertFalse(dictionarySlice.contains("\"kemPublic"))
        XCTAssertFalse(dictionarySlice.contains("\"kemPublicKey"))
        XCTAssertFalse(dictionarySlice.contains("\"suiteWireId"))
        XCTAssertFalse(dictionarySlice.contains("\"publicKey\""))
    }

    func testIOSBonjourTXTDictionaryDropsInjectedKEMMaterial() async throws {
        var txtRecord = NWTXTRecord()
        txtRecord["deviceId"] = "id:malicious-mac"
        txtRecord["name"] = "Malicious Mac"
        txtRecord["platform"] = "macOS"
        txtRecord["kemRefreshVersion"] = "1"
        txtRecord["kemKeyDigest"] = String(repeating: "c", count: 64)
        txtRecord["kemPublicKey"] = "malicious-kem-public-key"
        txtRecord["kemPublicKeys"] = "0x0001:malicious-kem-public-key"
        txtRecord["suiteWireId"] = "0x0001"
        txtRecord["publicKey"] = "malicious-public-key"

        await KEMTrustStore.shared.clearForTesting()
        let dictionary = try XCTUnwrap(txtRecord.dictionary)

        XCTAssertEqual(dictionary["deviceId"], "id:malicious-mac")
        XCTAssertEqual(dictionary["kemRefreshVersion"], "1")
        XCTAssertEqual(dictionary["kemKeyDigest"], String(repeating: "c", count: 64))
        XCTAssertNil(dictionary["kemPublicKey"])
        XCTAssertNil(dictionary["kempublickey"])
        XCTAssertNil(dictionary["kemPublicKeys"])
        XCTAssertNil(dictionary["kempublickeys"])
        XCTAssertNil(dictionary["suiteWireId"])
        XCTAssertNil(dictionary["suitewireid"])
        XCTAssertNil(dictionary["publicKey"])
        XCTAssertNil(dictionary["publickey"])
        let trustedKeys = await KEMTrustStore.shared.kemPublicKeys(forAny: ["id:malicious-mac"])
        XCTAssertTrue(trustedKeys.isEmpty)

        await KEMTrustStore.shared.clearForTesting()
    }

}

@available(iOS 17.0, *)
@MainActor
final class P2PBootstrapRekeyTargetTests: XCTestCase {
    private func readRepositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try readRepositorySourceForSourceShapeTests(
            at: repoRoot.appendingPathComponent(relativePath))
    }

    func testStrictPQCRecognizesCanonicalMLKEMAsSatisfyingForwardSecureTarget() {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.mlkem768],
                preferredTargetSuite: .mlkem768fs
            )
        )
    }

    func testSuiteSupportsTargetKEMTreatsFSAndCanonicalMLKEMAsEquivalent() {
        XCTAssertTrue(P2PConnectionManager.suiteSupportsTargetKEM(.mlkem768, target: .mlkem768fs))
        XCTAssertTrue(P2PConnectionManager.suiteSupportsTargetKEM(.mlkem768fs, target: .mlkem768))
        XCTAssertFalse(P2PConnectionManager.suiteSupportsTargetKEM(.xwing, target: .mlkem768fs))
    }

    func testInboundResponderRequiresXWingRuntimeSupportForXWingOnlyPeer() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/CryptoProviderFactory.swift"
        )
        let branchStart = try XCTUnwrap(source.range(of: "case (true, false):"))
        let branchEnd = try XCTUnwrap(source.range(of: "case (false, true):", range: branchStart.lowerBound..<source.endIndex))
        let xwingOnlyBranch = String(source[branchStart.lowerBound..<branchEnd.lowerBound])

        XCTAssertTrue(xwingOnlyBranch.contains("guard isAppleXWingAvailable() else"))
        XCTAssertTrue(xwingOnlyBranch.contains("return UnavailablePQCProvider()"))
        XCTAssertTrue(xwingOnlyBranch.contains("return AppleXWingCryptoProvider()"))
    }

    func testPreferredBootstrapRekeyTargetMatchesPreparedHandshakeOfferOrder() throws {
        let provider = CryptoProviderFactory.make(policy: .requirePQC)
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider,
            pqcOfferMode: .preferredSingle
        )

        XCTAssertEqual(
            P2PConnectionManager.preferredBootstrapRekeyTargetSuite(using: provider),
            preparation.offeredSuites.first
        )
    }
}
