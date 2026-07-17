import CryptoKit
import XCTest
@testable import SkyBridgeCore

final class QuantumCryptoManagerStrictPQCPolicyTests: XCTestCase {
    func testPQCOnlyEncryptDoesNotFallbackToClassicAES() throws {
        let manager = QuantumCryptoManager(mode: .pqcOnly)
        let key = SymmetricKey(size: .bits256)

        XCTAssertThrowsError(
            try manager.quantumSafeEncrypt(Data("strict-pqc-encrypt".utf8), using: key),
            "pqcOnly encryption must fail closed when PQC is unavailable or unconfigured."
        ) { error in
            Self.assertStrictPQCFailure(
                error,
                acceptedCodes: [-102, -100],
                operation: "加密"
            )
        }
    }

    func testPQCOnlyDecryptDoesNotFallbackToClassicAES() throws {
        let manager = QuantumCryptoManager(mode: .pqcOnly)
        let key = SymmetricKey(size: .bits256)

        XCTAssertThrowsError(
            try manager.quantumSafeDecrypt(Data("strict-pqc-decrypt".utf8), using: key),
            "pqcOnly decryption must fail closed when PQC is unavailable or unconfigured."
        ) { error in
            Self.assertStrictPQCFailure(
                error,
                acceptedCodes: [-103, -101],
                operation: "解密"
            )
        }
    }

    func testPQCFailuresAreNotSilentlyCollapsedWithTryQuestion() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/SkyBridgeCore/Security/P2PSecurityManager.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("try? encryptWithPQC"))
        XCTAssertFalse(source.contains("try? decryptWithPQC"))
        XCTAssertTrue(source.contains("NSUnderlyingErrorKey"))
        XCTAssertFalse(
            source.contains("automatic 模式按兼容策略回退到 AES-GCM"),
            "Once a PQC path has been selected, automatic mode must surface the PQC failure instead of documenting a success downgrade."
        )
        XCTAssertTrue(
            source.contains("所选 PQC 路径不得静默降级到 AES-GCM"),
            "PQC operation errors should preserve an explicit no-downgrade contract for diagnostics."
        )
    }

    func testQuantumCryptoManagerCapabilityRequiresXWingRuntimeProbe() throws {
        let source = try Self.readRepositorySource("Sources/SkyBridgeCore/Security/P2PSecurityManager.swift")
        let detectionBody = try Self.functionBody(
            named: "detectPQCCapability",
            in: source,
            before: "/// 生成对称密钥"
        )

        XCTAssertTrue(
            detectionBody.contains("PQCProviderFactory.supportsSuite(.hybridXWing)"),
            "QuantumCryptoManager must prove the exact X-Wing HPKE runtime it uses instead of treating SDK symbols or OS version as usable PQC."
        )
        XCTAssertTrue(
            detectionBody.contains("let hasXWingRuntime"),
            "Capability detection should name the runtime proof boundary so future readers do not confuse symbol presence with usable X-Wing."
        )
        XCTAssertFalse(
            detectionBody.contains("if #available(iOS 26.0, macOS 26.0, *) {\n                return (hasPQC: true"),
            "An OS availability branch alone must not mark app-layer PQC usable."
        )
        XCTAssertFalse(
            detectionBody.contains("algorithmType: .pqcHybrid)\n            }"),
            "The PQC hybrid capability should only be returned inside the runtime-proven branch."
        )
        XCTAssertTrue(
            source.contains("@available(iOS 26.0, macOS 26.0, *)\n    public func setHPKERecipientPublicKey"),
            "Shared HPKE key APIs must preserve iOS and macOS availability instead of exposing a macOS-only surface from shared core."
        )
        XCTAssertTrue(
            source.contains("@available(iOS 26.0, macOS 26.0, *)\n    public func setHPKERecipientPrivateKey"),
            "Shared HPKE private-key APIs must preserve iOS and macOS availability."
        )
    }

    func testQuantumCryptoManagerAutomaticRequiresOperationSpecificPQCReadiness() throws {
        let source = try Self.readRepositorySource("Sources/SkyBridgeCore/Security/P2PSecurityManager.swift")
        let encryptBody = try Self.functionBody(
            named: "quantumSafeEncrypt",
            in: source,
            before: "/// 解密"
        )
        let decryptBody = try Self.functionBody(
            named: "quantumSafeDecrypt",
            in: source,
            before: "// MARK: - 私有实现方法"
        )
        let readinessBody = try Self.functionBody(
            named: "shouldUsePQC",
            in: source,
            before: "private func hasHPKEKeyMaterial"
        )

        XCTAssertTrue(source.contains("private enum QuantumOperation"))
        XCTAssertTrue(encryptBody.contains("let usePQC = shouldUsePQC(for: .encrypt)"))
        XCTAssertTrue(decryptBody.contains("let usePQC = shouldUsePQC(for: .decrypt)"))
        XCTAssertTrue(
            readinessBody.contains("capabilityCache.hasPQC && hasHPKEKeyMaterial(for: operation)"),
            "automatic mode must require both runtime X-Wing proof and operation-specific HPKE key material before selecting PQC."
        )
        XCTAssertFalse(
            source.contains("recordPerf(encBytes: 0") || source.contains("recordPerf(decBytes: 0"),
            "A selected PQC failure must not be counted as a classic success before AES-GCM actually succeeds."
        )
        XCTAssertTrue(source.contains("classicSuccessCount"))
        XCTAssertFalse(
            source.contains("classicFallbackCount"),
            "Classic metrics should describe successful classic operations, not mix selected-PQC failures with AES-GCM success."
        )
    }

    func testQuantumCryptoManagerCurrentAlgorithmDoesNotExposeLocalCapabilityAsActiveProtection() throws {
        let source = try Self.readRepositorySource("Sources/SkyBridgeCore/Security/P2PSecurityManager.swift")
        let currentAlgorithmBody = try Self.declarationBody(
            startingAt: "public var currentAlgorithm",
            in: source,
            before: "/// 系统版本和本地 X-Wing runtime proof"
        )

        XCTAssertTrue(source.contains("public var localCapabilityAlgorithm: AlgorithmType"))
        XCTAssertTrue(source.contains("public var localPqcRuntimeAvailable: Bool"))
        XCTAssertTrue(
            currentAlgorithmBody.contains("guard mode != .classicOnly") &&
                currentAlgorithmBody.contains("return .classic") &&
                currentAlgorithmBody.contains("return capabilityCache.algorithmType"),
            "currentAlgorithm may return the local capability algorithm only after explicit active-protection guards pass."
        )
        XCTAssertTrue(
            currentAlgorithmBody.contains("hasHPKEKeyMaterial(for: .encrypt)") &&
                currentAlgorithmBody.contains("hasHPKEKeyMaterial(for: .decrypt)"),
            "currentAlgorithm should only report HPKE-X-Wing when both send and receive key material exist."
        )
        XCTAssertTrue(
            source.contains("不代表已协商或本次操作已使用"),
            "Local runtime capability fields must be documented as capability evidence, not session protection."
        )
    }

    func testTLSSecurityManagerHybridProfileRequiresExplicitPQCTransportMaterial() throws {
        let source = try Self.tlsSecurityManagerSource()

        XCTAssertTrue(
            source.contains("case .hybridXWing:\n                    encryptedData = try makeHybridXWingPayload"),
            "hybridXWing sends must enter the HPKE/X-Wing payload path instead of dropping into the generic automatic crypto manager."
        )
        XCTAssertTrue(
            source.contains("case .hybridXWing:\n                            decryptedData = try strongSelf.openHybridXWingPayload"),
            "hybridXWing receives must enter the HPKE/X-Wing open path instead of trying AES-GCM fallback."
        )
        XCTAssertTrue(
            source.contains("TLSSecurityError.pqcMaterialUnavailable"),
            "Missing HPKE provider or keychain key material must surface as an explicit TLS error."
        )
        XCTAssertFalse(source.contains("TLSQuantumCryptoManager"))
        XCTAssertFalse(source.contains("strictPQCQuantumCryptoManager"))
        XCTAssertFalse(source.contains("classicQuantumCryptoManager"))
        XCTAssertTrue(
            source.contains("case .pqcMlKemMlDsa, .classicP256:") &&
                source.contains("应用层安全数据仅支持 hybridXWing(真实 HPKE)"),
            "Non-hybrid profiles must fail explicitly instead of retaining a misleading transitional AES path."
        )
        XCTAssertFalse(
            source.contains("PQC Provider unavailable; fallback classic"),
            "PQC provider absence under a PQC/hybrid TLS profile must not be documented or logged as classic success."
        )
        XCTAssertFalse(
            source.contains("量子安全TLS"),
            "TLS connection setup must not claim quantum-safe TLS without negotiated-group evidence."
        )
        XCTAssertFalse(
            source.contains("if let hp = hpkeProvider, profile == .hybridXWing"),
            "Optional HPKE checks must not allow the hybridXWing path to fall through into AES-GCM."
        )
        XCTAssertTrue(
            source.contains("identityContext.outboundHybridAAD(") &&
                source.contains("identityContext.inboundHybridAAD("),
            "Hybrid X-Wing payloads must derive identical AAD on both peers from sender and recipient identity."
        )
        XCTAssertTrue(source.contains("identityContextByRemoteDeviceId"))
        XCTAssertFalse(source.contains("private var localDeviceId: String?"))
        XCTAssertFalse(
            source.contains("ctx.seal(data, authenticating: Data(recipientDeviceId.utf8))") ||
                source.contains("authenticating: Data(remoteDeviceId.utf8)"),
            "Hybrid X-Wing AAD must not use opposite one-sided device ids that make real peer decrypt fail."
        )
        XCTAssertTrue(
            source.contains("requiredAuthenticatedXWingRemotePublicKey") &&
                source.contains("requiredLocalXWingPrivateKey") &&
                source.contains("XWingKeyMaterialStore"),
            "TLS X-Wing send/receive consumers must use the reconciled role-specific store."
        )
        XCTAssertFalse(
            source.contains("PQCKeyTags.v2Kem") ||
                source.contains("requiredPQCKey("),
            "The shared v2 service must be migration-only, never an active TLS key reader."
        )
        XCTAssertTrue(
            source.contains("sec_protocol_options_set_peer_authentication_required") &&
                source.contains("sec_protocol_options_set_local_identity") &&
                source.contains("peerIsServer: true") &&
                source.contains("peerIsServer: false"),
            "Transport identity binding requires symmetric mTLS plus role-correct certificate policies."
        )
        XCTAssertTrue(source.contains("pendingConnections"))
        XCTAssertTrue(source.contains("case .ready:"))
        XCTAssertTrue(source.contains("throw TLSSecurityError.noMutualCryptoProfile"))
        XCTAssertFalse(
            source.contains("for p in offered { if supported.contains(p) { return p } }\n        return .classicP256")
        )
    }

    func testTLSConnectionIdentityContextBindsSymmetricRolesAndRejectsAliases() throws {
        let client = try TLSConnectionIdentityContext(
            localDeviceId: "device-a",
            remoteDeviceId: "device-b"
        )
        let server = try TLSConnectionIdentityContext(
            localDeviceId: "device-b",
            remoteDeviceId: "device-a"
        )
        let profile = TLSSecurityManager.CryptoProfile.hybridXWing.rawValue

        XCTAssertEqual(
            client.outboundHybridAAD(profile: profile),
            server.inboundHybridAAD(profile: profile)
        )
        XCTAssertEqual(
            server.outboundHybridAAD(profile: profile),
            client.inboundHybridAAD(profile: profile)
        )
        XCTAssertNotEqual(
            client.outboundHybridAAD(profile: profile),
            client.inboundHybridAAD(profile: profile)
        )

        for invalid in [
            "",
            " device-a",
            "device-a ",
            "device\na",
            "device\0a",
            String(repeating: "a", count: 257)
        ] {
            XCTAssertThrowsError(
                try TLSConnectionIdentityContext(
                    localDeviceId: invalid,
                    remoteDeviceId: "device-b"
                )
            )
            XCTAssertThrowsError(
                try TLSConnectionIdentityContext(
                    localDeviceId: "device-a",
                    remoteDeviceId: invalid
                )
            )
        }
        XCTAssertThrowsError(
            try TLSConnectionIdentityContext(
                localDeviceId: "same-device",
                remoteDeviceId: "same-device"
            )
        )

        // Length-prefixing prevents delimiter-bearing identities from
        // producing the same AAD tuple under a different role split.
        let delimiterBearing = try TLSConnectionIdentityContext(
            localDeviceId: "device|sender=x",
            remoteDeviceId: "recipient=y"
        )
        let alternateSplit = try TLSConnectionIdentityContext(
            localDeviceId: "device",
            remoteDeviceId: "sender=x|recipient=y"
        )
        XCTAssertNotEqual(
            delimiterBearing.outboundHybridAAD(profile: profile),
            alternateSplit.outboundHybridAAD(profile: profile)
        )
    }

    func testTLSConfigurationRejectsUnboundedOrIncoherentValues() throws {
        for invalidTimeout in [
            -1.0,
            0.0,
            301.0,
            Double.nan,
            Double.infinity
        ] {
            XCTAssertThrowsError(
                try TLSConfiguration(connectionTimeout: invalidTimeout)
            )
        }
        for invalidKeepalive in [
            -1.0,
            0.0,
            301.0,
            Double.nan,
            Double.infinity
        ] {
            XCTAssertThrowsError(
                try TLSConfiguration(keepaliveInterval: invalidKeepalive)
            )
        }
        XCTAssertThrowsError(
            try TLSConfiguration(
                enableCertificateVerification: false,
                requireClientCertificate: true
            )
        )
        XCTAssertNoThrow(try TLSConfiguration())
    }

    func testTLSSecurityManagerDoesNotCountTransportPQCWithoutNegotiatedGroupProof() throws {
        let source = try Self.tlsSecurityManagerSource()

        XCTAssertFalse(
            source.contains("let algoType = quantumCryptoManager.currentAlgorithm\n                if algoType != QuantumCryptoManager.AlgorithmType.classic"),
            "TLS connection metrics must not infer negotiated transport PQC from local QuantumCryptoManager capability."
        )
        XCTAssertTrue(
            source.contains("app-layer PQC payloads require explicit HPKE material"),
            "Logs should distinguish app-layer HPKE payload protection from unproven TLS negotiated-group PQC."
        )
    }

    func testTLSSecurityManagerCertificatePinningDoesNotTrustOnFirstUse() throws {
        let source = try Self.tlsSecurityManagerSource()
        let pinningBody = try Self.functionBody(
            named: "performCertificatePinning",
            in: source,
            before: "/// 验证经典 TLS 证书公钥强度下限"
        )

        XCTAssertTrue(
            pinningBody.contains("certificateManager.validateCertificate(leafCertificate, for: deviceId)"),
            "TLS handshake pinning must reuse the fail-closed certificate validator."
        )
        XCTAssertFalse(
            pinningBody.contains("storeFingerprint"),
            "TLS handshake verification must not establish trust-on-first-use by storing a previously unknown peer fingerprint."
        )
        XCTAssertFalse(
            pinningBody.contains("return true"),
            "TLS handshake pinning must not accept an unknown certificate as a success branch."
        )
        XCTAssertFalse(source.contains("CertificateFingerprint_"))
        XCTAssertFalse(source.contains("fingerprintCache"))
        XCTAssertFalse(
            source.contains("UserDefaults.standard"),
            "Legacy preferences/TOFU state must never override the scoped Keychain certificate identity."
        )
    }

    func testTLSSecurityManagerDoesNotNameClassicCertificatesQuantumSafe() throws {
        let source = try Self.tlsSecurityManagerSource()
        let builder = try Self.readRepositorySource(
            "Sources/SkyBridgeCore/Security/TLSSelfSignedCertificateBuilder.swift"
        )

        XCTAssertFalse(
            source.contains("validateQuantumSafeCertificate"),
            "TLS certificate key-strength checks must not be named as PQC certificate proof."
        )
        XCTAssertFalse(
            source.contains("量子安全证书"),
            "P-256/ECDSA TLS device certificates must not be labeled as quantum-safe certificates."
        )
        XCTAssertTrue(
            source.contains("validateClassicalCertificateKeyStrength"),
            "TLS certificates should keep a clear classical key-strength floor check."
        )
        XCTAssertTrue(
            source.contains("不作为 PQC 证明") || source.contains("不证明 PQC/quantum-safe 证书"),
            "Code comments should preserve the distinction between classical TLS certificate strength and PQC proof."
        )
        XCTAssertTrue(source.contains("kSecAttrKeyTypeECSECPrimeRandom"))
        XCTAssertTrue(source.contains("kSecAttrKeySizeInBits as String: 256"))
        XCTAssertTrue(
            builder.contains("ecdsaSignatureMessageX962SHA256"),
            "The side-effect-free certificate builder must sign with P-256/ECDSA-SHA256."
        )
    }

    func testTLSSecurityManagerRecoverableTrustFailureIsPinnedSelfSignedOnly() throws {
        let source = try Self.tlsSecurityManagerSource()
        let validityBody = try Self.functionBody(
            named: "validateCertificateValidity",
            in: source,
            before: "private func validatePinnedSelfSignedLocalCertificateContract"
        )
        let pinnedSelfSignedBody = try Self.functionBody(
            named: "validatePinnedSelfSignedLocalCertificateContract",
            in: source,
            before: "private func isSelfSignedCertificate"
        )

        XCTAssertTrue(validityBody.contains("case .recoverableTrustFailure:"))
        XCTAssertTrue(
            validityBody.contains("validatePinnedSelfSignedLocalCertificateContract(") &&
                validityBody.contains("peerIsServer: peerIsServer"),
            "Recoverable trust failures must be constrained to an explicit pinned self-signed local certificate contract."
        )
        XCTAssertTrue(validityBody.contains("SecPolicyCreateSSL(peerIsServer, nil)"))
        XCTAssertTrue(
            validityBody.contains(
                "guard SecTrustSetPolicies(trust, policy) == errSecSuccess"
            )
        )
        XCTAssertTrue(
            validityBody.contains(
                "guard SecTrustSetNetworkFetchAllowed("
            )
        )
        XCTAssertTrue(pinnedSelfSignedBody.contains("SecPolicyCreateSSL(peerIsServer, nil)"))
        XCTAssertFalse(
            validityBody.contains("证书信任问题，但可恢复") || validityBody.contains("在P2P场景中允许继续"),
            "Recoverable trust failures must not be broadly accepted as generic P2P self-signed certificates."
        )
        XCTAssertTrue(pinnedSelfSignedBody.contains("chain.count == 1"))
        XCTAssertTrue(pinnedSelfSignedBody.contains("certificateManager.validateCertificate(leafCertificate, for: deviceId)"))
        XCTAssertTrue(pinnedSelfSignedBody.contains("isSelfSignedCertificate(leafCertificate)"))
        XCTAssertTrue(pinnedSelfSignedBody.contains("SecTrustSetAnchorCertificates(pinnedTrust, [leafCertificate] as CFArray)"))
        XCTAssertTrue(pinnedSelfSignedBody.contains("SecTrustSetAnchorCertificatesOnly(pinnedTrust, true)"))
        XCTAssertTrue(pinnedSelfSignedBody.contains("guard SecTrustSetNetworkFetchAllowed("))
        XCTAssertTrue(pinnedSelfSignedBody.contains("SecTrustEvaluateWithError(pinnedTrust"))
    }

    func testTLSSecurityManagerUsesPerDeviceCryptoProfilesForApplicationPayloads() throws {
        let source = try Self.tlsSecurityManagerSource()

        XCTAssertTrue(
            source.contains("private var cryptoProfileByDeviceId: [String: CryptoProfile] = [:]"),
            "TLS crypto profile state must be keyed by device instead of stored in one manager-wide mutable selectedProfile."
        )
        XCTAssertTrue(
            source.contains("private func cryptoProfile(for deviceId: String) throws -> CryptoProfile"),
            "Application payload encryption/decryption should resolve the negotiated profile through an explicit per-device accessor."
        )
        XCTAssertTrue(
            source.contains("throw TLSSecurityError.cryptoProfileMissing(deviceId: deviceId)"),
            "Missing negotiated crypto profile state must fail closed instead of falling back to classic crypto."
        )
        XCTAssertTrue(
            source.contains("profile = try cryptoProfile(for: deviceId)"),
            "Both send and receive paths should require recorded crypto profile state before processing payloads."
        )
        XCTAssertFalse(
            source.contains("private var selectedProfile"),
            "Manager-wide selectedProfile can be overwritten by another connection and must not drive application payload crypto."
        )
        XCTAssertFalse(
            source.contains("let profile = selectedProfile"),
            "Send/receive paths must not read a global mutable profile."
        )
        XCTAssertTrue(
            source.contains("private var pqcProviderByDeviceId: [String: PQCProvider] = [:]"),
            "PQC provider state must be keyed by device so classic connections cannot clear another connection's PQC context."
        )
        XCTAssertTrue(
            source.contains("private var hpkeProviderByDeviceId: [String: PQCHPKEProvider] = [:]"),
            "HPKE provider state must be keyed by device for hybrid X-Wing payloads."
        )
        XCTAssertTrue(
            source.contains("clearPQCProvider(for: deviceId)") &&
                source.contains("pqcProviderByDeviceId.removeAll()") &&
                source.contains("hpkeProviderByDeviceId.removeAll()"),
            "Connection teardown must clear per-device PQC/HPKE provider state instead of leaving stale hidden state."
        )
    }

    func testTLSSecurityManagerDoesNotNegotiateXWingFromHardcodedLocalProfiles() throws {
        let source = try Self.tlsSecurityManagerSource()

        XCTAssertFalse(
            source.contains("let offered: [CryptoProfile] = [.hybridXWing, .pqcMlKemMlDsa, .classicP256]"),
            "Server-side TLS setup must not synthesize a peer offer that selects X-Wing without authenticated peer capability evidence."
        )
        XCTAssertFalse(
            source.contains("let supported: [CryptoProfile] = [.hybridXWing, .classicP256]"),
            "Supported profile lists must be derived from suite-specific provider evidence, not a hardcoded local array."
        )
        XCTAssertTrue(
            source.contains("negotiateApplicationCryptoProfile(") &&
                source.contains("peerOfferedProfiles: nil"),
            "When no authenticated peer profile offer exists, TLS setup should explicitly negotiate the application crypto profile as classic."
        )
        XCTAssertTrue(
            source.contains("PQCProviderFactory.supportsSuite(.hybridXWing)"),
            "Local X-Wing support must be derived from a suite-specific runtime probe."
        )
        XCTAssertTrue(
            source.contains("PQCProviderFactory.makeHPKEProvider(for: .hybridXWing)"),
            "Selecting hybridXWing must require an explicit X-Wing HPKE provider."
        )
    }

    func testWebRTCSmokeDiagnosticsDoNotPrintUnknownPlaintextPreview() throws {
        let source = try Self.readRepositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )

        XCTAssertFalse(
            source.contains("plaintext unknown preview"),
            "Smoke diagnostics must not print decrypted plaintext for unknown WebRTC app messages."
        )
        XCTAssertFalse(
            source.contains("plaintext.prefix(256)"),
            "Smoke diagnostics must not dump a prefix of decrypted plaintext."
        )
        XCTAssertTrue(
            source.contains("unknown payload length=") && source.contains("sha256Prefix="),
            "Smoke diagnostics should keep only bounded metadata for unknown decrypted payloads."
        )
    }

    func testWebRTCRekeyCompletionEventsAreBoundToNegotiatedPQCSuites() throws {
        let macSource = try Self.readRepositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let iOSSource = try Self.readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )

        for source in [macSource, iOSSource] {
            XCTAssertTrue(
                source.contains("? \"pqcRekeyComplete\""),
                "WebRTC rekey logs must emit pqcRekeyComplete only from a negotiated PQC-suite branch."
            )
            XCTAssertTrue(
                source.contains(": \"classicRekeyComplete\""),
                "Classic compatibility rekeys must have an explicit non-PQC completion event."
            )
            XCTAssertFalse(
                source.contains("event=pqcRekeyComplete suite="),
                "Rekey logs must not unconditionally label the negotiated suite as PQC."
            )
        }
    }

    func testPairingIdentityExchangeKEMBootstrapFailsClosedWhenTrustSyncPersistenceFails() throws {
        let p2pSource = try Self.readRepositorySource("Sources/SkyBridgeCore/P2P/P2PModels.swift")
        let bootstrapStoreSource = try Self.readRepositorySource("Sources/SkyBridgeCore/P2P/PeerKEMBootstrapStore.swift")
        let persistenceBody = try Self.functionBody(
            named: "persistPeerKEMTrustRecords",
            in: p2pSource,
            before: "@available(macOS 14.0, iOS 17.0, *)\n    @MainActor"
        )
        let cacheClearBody = try Self.functionBody(
            named: "clearPairingIdentityExchangeEntries",
            in: bootstrapStoreSource,
            before: "func clearForTesting()"
        )

        XCTAssertTrue(
            persistenceBody.contains("if savedIds.isEmpty, let lastError"),
            "The pairing identity exchange importer must separate full TrustSync persistence failure from partial success."
        )
        XCTAssertTrue(
            persistenceBody.contains("clearPairingIdentityExchangeEntries(deviceIds: bootstrapIds)"),
            "Unsigned bootstrap KEM material must be removed when TrustSync persists zero records."
        )
        XCTAssertTrue(
            persistenceBody.contains("throw lastError"),
            "TrustSync persistence failure must remain observable instead of continuing with bootstrap-only KEM material."
        )
        XCTAssertFalse(
            persistenceBody.contains("using bootstrap cache only"),
            "TrustSync failure must not degrade into a bootstrap-cache-only trust path."
        )
        XCTAssertFalse(
            persistenceBody.contains("TrustSync degraded"),
            "The importer must not log TrustSync failure as a usable degraded state."
        )
        XCTAssertTrue(
            cacheClearBody.contains("entries[deviceId]?.source == \"pairing_identity_exchange\""),
            "The cleanup path should remove only unsigned pairing exchange entries."
        )
        XCTAssertFalse(
            cacheClearBody.contains("signed_lan_kem_refresh"),
            "Signed SKR-1 refresh cache must survive the unsigned bootstrap cleanup path."
        )
    }

    @available(macOS 14.0, *)
    func testLegacyHybridCryptoCanFailClosedWhenPQCIsRequiredForKeyExchange() async throws {
        let service = HybridCryptoService(
            pqcAdapter: PQCProtocolAdapter(provider: nil, suite: .classic),
            degradationPolicy: .requirePQCComponent
        )
        let remoteKey = P256.KeyAgreement.PrivateKey()

        do {
            _ = try await service.initiateHybridKeyExchange(
                peerId: "strict-legacy-hybrid-key-exchange",
                remoteClassicPublicKey: remoteKey.publicKey.rawRepresentation
            )
            XCTFail("Strict legacy hybrid key exchange must fail closed when the PQC component is unavailable.")
        } catch let error as HybridCryptoError {
            XCTAssertEqual(error.localizedDescription, HybridCryptoError.degradationNotAllowed.localizedDescription)
        }
    }

    func testPQCProviderFactoryRequiresSuiteSpecificXWingHPKEProbe() throws {
        let source = try Self.readRepositorySource("Sources/SkyBridgeCore/QuantumSecure/PQCProvider.swift")
        let makeHPKEProviderBody = try Self.functionBody(
            named: "makeHPKEProvider(for suite: PQCAlgorithmSuite)",
            in: source,
            before: "public static func supportsSuite"
        )

        XCTAssertTrue(
            source.contains("case .hybridXWing:\n            return makeHPKEProvider(") &&
                source.contains("for: .hybridXWing,\n                scopeSource: scopeSource"),
            "Generic provider selection must route hybridXWing through the HPKE-specific provider path."
        )
        XCTAssertTrue(
            makeHPKEProviderBody.contains("isAppleXWingHPKEAvailable()"),
            "X-Wing provider availability must be proven by the X-Wing HPKE runtime probe."
        )
        XCTAssertFalse(
            makeHPKEProviderBody.contains("isApplePQCAvailable()"),
            "ML-KEM/ML-DSA availability must not be reused as proof that X-Wing HPKE is usable."
        )
        XCTAssertTrue(source.contains("private static func isAppleXWingHPKEAvailable() -> Bool"))
        XCTAssertTrue(source.contains("HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256"))
        XCTAssertTrue(source.contains("recipient.open(ciphertext, authenticating: info) == plaintext"))
        XCTAssertTrue(
            source.contains("return ApplePQCProvider(\n                suite: .hybridXWing,"),
            "X-Wing factory output must carry hybridXWing suite metadata."
        )
        XCTAssertTrue(
            source.contains("return ApplePQCProvider(\n                        suite: .pqcMlKemMlDsa,"),
            "ML-KEM/ML-DSA factory output must carry ML-KEM/ML-DSA suite metadata."
        )
        XCTAssertTrue(source.contains("nonisolated let suite: PQCAlgorithmSuite"))
        XCTAssertFalse(
            source.contains("nonisolated var suite: PQCAlgorithmSuite { .pqcMlKemMlDsa }"),
            "Apple X-Wing provider metadata must not report the ML-KEM/ML-DSA suite."
        )
    }

    func testPQCProviderVerificationAndHPKEDoNotUseLocalSelfConsistencyProofs() throws {
        let source = try Self.readRepositorySource("Sources/SkyBridgeCore/QuantumSecure/PQCProvider.swift")

        XCTAssertFalse(
            source.contains("lastSignatures"),
            "PQC signature verification must never be rescued by a local sign cache."
        )
        XCTAssertTrue(
            source.contains("let recipientKey = try loadExistingXWingPublicKey(recipientPeerId)"),
            "Peer-id HPKE sealing must require an existing authenticated peer public key."
        )
        XCTAssertTrue(
            source.contains("func setAuthenticatedXWingRecipientPublicKey"),
            "Tests and trusted handshake ingestion need an explicit way to register authenticated X-Wing recipient public keys."
        )
        XCTAssertTrue(
            source.contains("func setLocalXWingRecipientPrivateKey"),
            "HPKE open must use explicitly registered local X-Wing private key material instead of creating peer keys during seal."
        )
        XCTAssertFalse(
            source.contains("getOrCreateXWingKey(recipientPeerId).publicKey"),
            "HPKE sealing must not create recipient private material locally and call that remote proof."
        )
    }

    func testPQCProviderKeychainPersistenceFailuresFailClosedAndRedactIdentifiers() throws {
        let providerSource = try Self.readRepositorySource("Sources/SkyBridgeCore/QuantumSecure/PQCProvider.swift")
        let oqsBridgeSource = try Self.readRepositorySource("Sources/SkyBridgeCore/QuantumSecure/OQSBridge.swift")

        XCTAssertTrue(
            providerSource.contains("XWingKeyMaterialStore.persistAuthenticatedRemotePublicKey") &&
                providerSource.contains("KeychainManager.shared.insertKeyIfAbsent") &&
                providerSource.contains("loadAuthoritativeRemotePublicKey"),
            "X-Wing persistence must use add-only CAS and reload the immutable winner."
        )
        XCTAssertFalse(
            providerSource.contains("_ = KeychainManager.shared.importKey"),
            "PQCProvider must not ignore keychain persistence failures and then return process-local key material."
        )
        XCTAssertFalse(
            providerSource.contains(#"\(failureDescription): \(account)"#),
            "PQCProvider keychain errors must not include raw peer/account identifiers."
        )
        XCTAssertFalse(providerSource.contains(#"缺少已认证的X-Wing对端公钥: \(peerId)"#))
        XCTAssertFalse(providerSource.contains(#"缺少本地X-Wing私钥: \(peerId)"#))
        XCTAssertTrue(providerSource.contains("缺少已认证的X-Wing对端公钥"))
        XCTAssertTrue(providerSource.contains("缺少本地X-Wing私钥"))

        XCTAssertTrue(
            oqsBridgeSource.contains("PQCKeyPairStore.loadOrCreate"),
            "OQS key material must use the canonical create-only pair store."
        )
        XCTAssertFalse(
            oqsBridgeSource.contains("_ = KeychainManager.shared.importKey"),
            "OQSBridge must not ignore keychain persistence failures in liboqs-backed compatibility paths."
        )
        XCTAssertFalse(oqsBridgeSource.contains(#":: \(peerId)"#))
    }

    @available(macOS 14.0, *)
    func testLegacyHybridCryptoCanFailClosedWhenPQCIsRequiredForSignature() async throws {
        let service = HybridCryptoService(
            pqcAdapter: PQCProtocolAdapter(provider: nil, suite: .classic),
            degradationPolicy: .requirePQCComponent
        )
        let signingKey = P256.Signing.PrivateKey()

        do {
            _ = try await service.createHybridSignature(
                data: Data("strict-legacy-hybrid-signature".utf8),
                peerId: "strict-legacy-hybrid-signature",
                classicPrivateKey: signingKey.rawRepresentation
            )
            XCTFail("Strict legacy hybrid signatures must fail closed when the PQC component is unavailable.")
        } catch let error as HybridCryptoError {
            XCTAssertEqual(error.localizedDescription, HybridCryptoError.degradationNotAllowed.localizedDescription)
        }
    }

    private static func tlsSecurityManagerSource() throws -> String {
        try readRepositorySource("Sources/SkyBridgeCore/Security/TLSSecurityManager.swift")
    }

    private static func assertStrictPQCFailure(
        _ error: Error,
        acceptedCodes: Set<Int>,
        operation: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let nsError = error as NSError
        XCTAssertEqual(nsError.domain, "QuantumCrypto", file: file, line: line)
        XCTAssertTrue(
            acceptedCodes.contains(nsError.code),
            "Expected strict PQC \(operation) error code in \(acceptedCodes), got \(nsError.code)",
            file: file,
            line: line
        )
        let description = nsError.userInfo[NSLocalizedDescriptionKey] as? String
        XCTAssertNotNil(description, file: file, line: line)
        XCTAssertTrue(description?.contains("PQC") == true, file: file, line: line)
        XCTAssertTrue(description?.contains(operation) == true, file: file, line: line)
    }

    private static func functionBody(named functionName: String, in source: String, before terminator: String) throws -> String {
        guard let start = source.range(of: "func \(functionName)") else {
            XCTFail("Missing function \(functionName)")
            return ""
        }
        guard let end = source[start.lowerBound...].range(of: terminator) else {
            XCTFail("Missing terminator for function \(functionName)")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func declarationBody(startingAt marker: String, in source: String, before terminator: String) throws -> String {
        guard let start = source.range(of: marker) else {
            XCTFail("Missing declaration marker \(marker)")
            return ""
        }
        guard let end = source[start.lowerBound...].range(of: terminator) else {
            XCTFail("Missing terminator for declaration marker \(marker)")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func readRepositorySource(_ path: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
