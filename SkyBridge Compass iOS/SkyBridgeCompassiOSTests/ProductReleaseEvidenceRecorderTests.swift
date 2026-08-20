import XCTest
import CryptoKit
@testable import SkyBridgeCompass_iOS
import SkyBridgeProtocolCore

@MainActor
final class ProductReleaseEvidenceRecorderTests: XCTestCase {
    private let sessionReference = "ev1:0123456789abcdef0123456789abcdef"

    func testAuthenticatedEndpointUsesLocalProfileWithoutPeerInference() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let owner = try XCTUnwrap(recorder.beginAttempt(
            attemptReference: "at1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            role: .responder,
            localProfile: .xwing,
            offeredSuites: [.xwing, .mlkem768],
            requirePQC: true,
            allowClassicFallback: false
        ))

        XCTAssertTrue(recorder.authenticate(
            owner: owner,
            sessionReference: sessionReference,
            negotiatedSuite: .mlkem768
        ))
        XCTAssertFalse(recorder.authenticate(
            owner: owner,
            sessionReference: sessionReference,
            negotiatedSuite: .mlkem768
        ))

        let endpoint = try XCTUnwrap(lines.last)
        XCTAssertTrue(endpoint.hasPrefix("connectivityEndpoint "))
        XCTAssertTrue(endpoint.contains("owner=SkyBridgeCompassiOS"))
        XCTAssertTrue(endpoint.contains("generation=1"))
        XCTAssertTrue(endpoint.contains("role=responder"))
        XCTAssertTrue(endpoint.contains("localProfile=xwing"))
        XCTAssertTrue(endpoint.contains("offeredProfiles=pqc+xwing"))
        XCTAssertTrue(endpoint.contains("attemptProfile=pqc"))
        XCTAssertFalse(endpoint.contains("peerProfile="))
    }

    func testLocalProfileMustBePresentInActualOfferedProfiles() {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        XCTAssertNil(recorder.beginAttempt(
            attemptReference: "at1:abababababababababababababababab",
            role: .initiator,
            localProfile: .xwing,
            offeredSuites: [.mlkem768],
            requirePQC: true,
            allowClassicFallback: false
        ))
        XCTAssertNil(recorder.beginAttempt(
            attemptReference: "at1:acacacacacacacacacacacacacacacac",
            role: .initiator,
            localProfile: .pqc,
            offeredSuites: [.xwing],
            requirePQC: true,
            allowClassicFallback: false
        ))
        XCTAssertTrue(lines.isEmpty)
    }

    func testStrictResponderRecordsExpectedClassicOfferRejection() async throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let peerMessageA = try signedClassicOffer(attemptByte: 0xbb)

        let accepted = await recorder.recordStrictPQCClassicOfferRejection(
            peerMessageA: peerMessageA,
            localProfile: .pqc,
            offeredSuites: [.mlkem768]
        )
        XCTAssertTrue(accepted)
        let acceptedReplay = await recorder.recordStrictPQCClassicOfferRejection(
            peerMessageA: peerMessageA,
            localProfile: .pqc,
            offeredSuites: [.mlkem768]
        )
        XCTAssertFalse(acceptedReplay)
        XCTAssertTrue(lines.last?.contains("peerOfferSignature=verified") == true)
        XCTAssertTrue(lines.last?.contains("reason=strict-pqc-rejects-classic result=rejected") == true)
        XCTAssertFalse(lines.contains { $0.hasPrefix("connectivityEndpoint ") })
    }

    func testStrictRejectionVerifierRejectsAnInvalidClassicSignature() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signed = try signedClassicOffer(
            attemptByte: 0xcc,
            signingKey: privateKey
        )
        let invalidSignature = SkyBridgeCompass_iOS.HandshakeMessageA(
            supportedSuites: signed.supportedSuites,
            keyShares: signed.keyShares,
            clientNonce: signed.clientNonce,
            policy: signed.policy,
            capabilities: signed.capabilities,
            signature: Data(repeating: 0, count: signed.signature.count),
            identityPublicKey: signed.identityPublicKey,
            extensionsRaw: signed.extensionsRaw
        )
        let tamperedSuite = SkyBridgeCompass_iOS.HandshakeMessageA(
            supportedSuites: [.mlkem768],
            keyShares: signed.keyShares,
            clientNonce: signed.clientNonce,
            policy: signed.policy,
            capabilities: signed.capabilities,
            signature: signed.signature,
            identityPublicKey: signed.identityPublicKey,
            extensionsRaw: signed.extensionsRaw
        )
        let tamperedPolicy = SkyBridgeCompass_iOS.HandshakeMessageA(
            supportedSuites: signed.supportedSuites,
            keyShares: signed.keyShares,
            clientNonce: signed.clientNonce,
            policy: .strictPQC,
            capabilities: signed.capabilities,
            signature: signed.signature,
            identityPublicKey: signed.identityPublicKey,
            extensionsRaw: signed.extensionsRaw
        )
        let changedSOA = try SkyBridgeCompass_iOS.HandshakeSOAExtension(
            initiatorPeerId: Data(repeating: 0x81, count: 32),
            targetPeerId: Data(repeating: 0x82, count: 32),
            attemptId: Data(repeating: 0xcd, count: 16)
        )
        let tamperedAttempt = SkyBridgeCompass_iOS.HandshakeMessageA(
            supportedSuites: signed.supportedSuites,
            keyShares: signed.keyShares,
            clientNonce: signed.clientNonce,
            policy: signed.policy,
            capabilities: signed.capabilities,
            signature: signed.signature,
            identityPublicKey: signed.identityPublicKey,
            extensionsRaw: changedSOA.encodedTLV
        )
        let wrongIdentityKey = Curve25519.Signing.PrivateKey()
        let wrongIdentity = SkyBridgeCompass_iOS.IdentityPublicKeys(
            protocolPublicKey: wrongIdentityKey.publicKey.rawRepresentation,
            protocolAlgorithm: .ed25519
        )
        let signedByWrongKey = try signedClassicOffer(
            attemptByte: 0xce,
            signingKey: privateKey,
            identity: wrongIdentity
        )

        for rejectedMessage in [
            invalidSignature, tamperedSuite, tamperedPolicy,
            tamperedAttempt, signedByWrongKey
        ] {
            var lines: [String] = []
            let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
            let accepted = await recorder.recordStrictPQCClassicOfferRejection(
                peerMessageA: rejectedMessage,
                localProfile: .pqc,
                offeredSuites: [.mlkem768]
            )
            XCTAssertFalse(accepted)
            XCTAssertTrue(lines.isEmpty)
        }
    }

    func testConcurrentClassicOfferReplayEmitsOneTerminalPair() async throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let offer = try signedClassicOffer(attemptByte: 0xcf)

        let first = Task { @MainActor in
            await recorder.recordStrictPQCClassicOfferRejection(
                peerMessageA: offer,
                localProfile: .pqc,
                offeredSuites: [.mlkem768]
            )
        }
        let second = Task { @MainActor in
            await recorder.recordStrictPQCClassicOfferRejection(
                peerMessageA: offer,
                localProfile: .pqc,
                offeredSuites: [.mlkem768]
            )
        }
        let results = [await first.value, await second.value]

        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(lines.filter { $0.hasPrefix("connectivityAttemptStarted ") }.count, 1)
        XCTAssertEqual(lines.filter { $0.hasPrefix("connectivityPolicyRejected ") }.count, 1)
    }

    func testClassicRejectionReplayStateHasFailClosedCapacityBound() async throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        for index in 0..<ProductReleaseEvidenceRecorder
            .maximumRetainedRejectionCount {
            let accepted = await recorder.recordStrictPQCClassicOfferRejection(
                peerMessageA: try signedClassicOffer(attemptByte: UInt8(index)),
                localProfile: .pqc,
                offeredSuites: [.mlkem768]
            )
            XCTAssertTrue(accepted)
        }
        let overflowAccepted = await recorder.recordStrictPQCClassicOfferRejection(
            peerMessageA: try signedClassicOffer(attemptByte: 0xfe),
            localProfile: .pqc,
            offeredSuites: [.mlkem768]
        )

        XCTAssertFalse(overflowAccepted)
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("connectivityPolicyRejected ") }.count,
            ProductReleaseEvidenceRecorder.maximumRetainedRejectionCount
        )
    }

    func testProductionIdentityLifecycleEventsAreStrictOneShotAndSecretFree() throws {
        var firstLaunchLines: [String] = []
        let firstLaunchRecorder = ProductReleaseEvidenceRecorder {
            firstLaunchLines.append($0)
        }
        let descriptor = try XCTUnwrap(ProductIdentityEvidenceDescriptor(
            identityReference: "id1:0123456789abcdef0123456789abcdef",
            algorithm: .mlDSA87,
            protection: .secureEnclaveRequired
        ))

        XCTAssertTrue(firstLaunchRecorder.recordProductionIdentityCommitted(descriptor))
        XCTAssertFalse(firstLaunchRecorder.recordProductionIdentityCommitted(descriptor))
        XCTAssertFalse(firstLaunchRecorder.recordProductionIdentityRestored(descriptor))
        XCTAssertFalse(firstLaunchRecorder.recordProductionIdentityHandshakeBound(
            descriptor: descriptor,
            sessionOwner: try XCTUnwrap(firstLaunchRecorder.beginSession(
                transport: .p2p,
                sessionReference: sessionReference,
                routeClass: .wifi
            )),
            attemptReference: "at1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ))

        var secondLaunchLines: [String] = []
        let secondLaunchRecorder = ProductReleaseEvidenceRecorder {
            secondLaunchLines.append($0)
        }
        XCTAssertFalse(secondLaunchRecorder.recordProductionIdentityHandshakeBound(
            descriptor: descriptor,
            sessionOwner: try XCTUnwrap(secondLaunchRecorder.beginSession(
                transport: .p2p,
                sessionReference: sessionReference,
                routeClass: .wifi
            )),
            attemptReference: "at1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ))
        XCTAssertTrue(secondLaunchRecorder.recordProductionIdentityRestored(descriptor))
        XCTAssertFalse(secondLaunchRecorder.recordProductionIdentityRestored(descriptor))
        let authenticatedOwner = try XCTUnwrap(secondLaunchRecorder.beginSession(
            transport: .p2p,
            sessionReference: "ev1:11111111111111111111111111111111",
            routeClass: .wifi
        ))
        XCTAssertTrue(secondLaunchRecorder.recordP2PSessionAuthenticated(
            owner: authenticatedOwner,
            role: .initiator,
            suite: .xwing
        ))
        XCTAssertTrue(secondLaunchRecorder.recordProductionIdentityHandshakeBound(
            descriptor: descriptor,
            sessionOwner: authenticatedOwner,
            attemptReference: "at1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ))
        XCTAssertFalse(secondLaunchRecorder.recordProductionIdentityHandshakeBound(
            descriptor: descriptor,
            sessionOwner: authenticatedOwner,
            attemptReference: "at1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ))

        XCTAssertEqual(
            firstLaunchLines.filter { $0.hasPrefix("productionIdentity") }
                .map { $0.split(separator: " ").first.map(String.init) },
            ["productionIdentityCommitted"]
        )
        XCTAssertEqual(secondLaunchLines.filter { $0.hasPrefix("productionIdentity") }.map {
            $0.split(separator: " ").first.map(String.init)
        }, [
            "productionIdentityRestored",
            "productionIdentityHandshakeBound",
        ])
        let lines = firstLaunchLines + secondLaunchLines
        let output = lines.joined(separator: "\n")
        XCTAssertTrue(output.contains("identity_ref=id1:0123456789abcdef0123456789abcdef"))
        XCTAssertTrue(output.contains("algorithm=mldsa87"))
        XCTAssertTrue(output.contains("protection=secureEnclaveRequired"))
        for forbidden in [
            "privateKey", "publicKey", "fingerprint", "device=", "deviceId=",
            "user=", "account=", "ip=", "IP=", "raw="
        ] {
            XCTAssertFalse(output.contains(forbidden), "Unexpected secret field: \(forbidden)")
        }
    }

    func testProductionIdentityEvidenceRejectsNonFormalProtectionAndAlgorithm() throws {
        var lines: [String] = []
        let softwareProtected = try XCTUnwrap(ProductIdentityEvidenceDescriptor(
            identityReference: "id1:11111111111111111111111111111111",
            algorithm: .mlDSA87,
            protection: .softwareKeychain
        ))
        let lowerStrengthAlgorithm = try XCTUnwrap(ProductIdentityEvidenceDescriptor(
            identityReference: "id1:22222222222222222222222222222222",
            algorithm: .mlDSA65,
            protection: .secureEnclaveRequired
        ))

        for (index, descriptor) in [softwareProtected, lowerStrengthAlgorithm].enumerated() {
            let isolatedRecorder = ProductReleaseEvidenceRecorder { lines.append($0) }
            let reference = index == 0
                ? "ev1:33333333333333333333333333333333"
                : "ev1:44444444444444444444444444444444"
            let owner = try XCTUnwrap(isolatedRecorder.beginSession(
                transport: .p2p,
                sessionReference: reference,
                routeClass: .wifi
            ))
            XCTAssertTrue(isolatedRecorder.recordP2PSessionAuthenticated(
                owner: owner,
                role: .initiator,
                suite: .xwing
            ))
            XCTAssertFalse(isolatedRecorder.recordProductionIdentityCommitted(descriptor))
            XCTAssertFalse(isolatedRecorder.recordProductionIdentityRestored(descriptor))
            XCTAssertFalse(isolatedRecorder.recordProductionIdentityHandshakeBound(
                descriptor: descriptor,
                sessionOwner: owner,
                attemptReference: "at1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            ))
        }
        XCTAssertFalse(lines.contains { $0.hasPrefix("productionIdentity") })
    }

    func testWebRTCIdentityBindingRequiresAuthenticatedOwnerAndNoFakeAttempt() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let descriptor = try XCTUnwrap(ProductIdentityEvidenceDescriptor(
            identityReference: "id1:55555555555555555555555555555555",
            algorithm: .mlDSA87,
            protection: .secureEnclaveRequired
        ))
        let owner = try XCTUnwrap(recorder.beginSession(
            transport: .webrtc,
            sessionReference: sessionReference,
            selectedTransport: .relay
        ))

        XCTAssertTrue(recorder.recordProductionIdentityRestored(descriptor))
        XCTAssertFalse(recorder.recordProductionIdentityHandshakeBound(
            descriptor: descriptor,
            sessionOwner: owner
        ))
        XCTAssertTrue(recorder.recordWebRTCPQCRekeyAuthenticated(
            owner: owner,
            suite: .xwing
        ))
        XCTAssertFalse(recorder.recordProductionIdentityHandshakeBound(
            descriptor: descriptor,
            sessionOwner: owner,
            attemptReference: "at1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ))
        XCTAssertTrue(recorder.recordProductionIdentityHandshakeBound(
            descriptor: descriptor,
            sessionOwner: owner
        ))
        XCTAssertTrue(lines.last?.contains("transport=webrtc") == true)
        XCTAssertTrue(lines.last?.contains("attempt_ref=not-applicable") == true)
    }

    func testGenericP2PFileTransferOwnerIsSingleSlotAndStaleSafe() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let owner = try XCTUnwrap(recorder.beginSession(
            transport: .p2p,
            sessionReference: sessionReference,
            routeClass: .wifi
        ))
        XCTAssertTrue(recorder.recordP2PSessionAuthenticated(
            owner: owner,
            role: .initiator,
            suite: .xwing
        ))
        XCTAssertFalse(recorder.recordP2PSessionAuthenticated(
            owner: owner,
            role: .initiator,
            suite: .xwing
        ))
        let transfer = "ev1:fedcba9876543210fedcba9876543210"
        XCTAssertTrue(recorder.recordFileTransferStarted(
            owner: owner,
            transferReference: transfer,
            direction: .send
        ))
        XCTAssertFalse(recorder.recordFileTransferStarted(
            owner: owner,
            transferReference: "ev1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            direction: .receive
        ))
        XCTAssertFalse(recorder.recordFileTransferCompleted(
            owner: owner,
            transferReference: transfer,
            direction: .send,
            authenticatedReceipt: false,
            integrityVerified: true,
            uiEffectVisible: true
        ))
        XCTAssertTrue(recorder.recordFileTransferCompleted(
            owner: owner,
            transferReference: transfer,
            direction: .send,
            authenticatedReceipt: true,
            integrityVerified: true,
            uiEffectVisible: true
        ))
        XCTAssertTrue(recorder.endSession(owner: owner, reason: .user))
        XCTAssertFalse(recorder.endSession(owner: owner, reason: .user))
        XCTAssertFalse(recorder.recordFileTransferCompleted(
            owner: owner,
            transferReference: transfer,
            direction: .send,
            authenticatedReceipt: true,
            integrityVerified: true,
            uiEffectVisible: true
        ))
        XCTAssertEqual(lines.map { $0.split(separator: " ").first.map(String.init) }, [
            "releaseSessionOwner",
            "p2pSessionAuthenticated",
            "fileTransferStarted",
            "fileTransferCompleted",
            "releaseSessionDisconnected",
        ])
        XCTAssertTrue(lines.last?.contains("noticeHidden=not-applicable") == true)
        XCTAssertFalse(lines.last?.contains("noticeHidden=1") == true)
    }

    func testWebRTCMediaSamplesAreBoundedOrderedAndMonotonic() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let owner = try XCTUnwrap(recorder.beginSession(
            transport: .webrtc,
            sessionReference: sessionReference,
            selectedTransport: .relay
        ))
        XCTAssertTrue(recorder.recordWebRTCPQCRekeyAuthenticated(
            owner: owner,
            suite: .xwing
        ))
        let first = try XCTUnwrap(ProductEvidenceMediaSample(
            role: .receiver,
            sequence: 1,
            elapsedMilliseconds: 1_000,
            videoFrames: 10,
            videoBytes: 1_000,
            audioUnits: 20,
            audioBytes: 2_000
        ))
        let stale = try XCTUnwrap(ProductEvidenceMediaSample(
            role: .receiver,
            sequence: 2,
            elapsedMilliseconds: 31_000,
            videoFrames: 10,
            videoBytes: 2_000,
            audioUnits: 30,
            audioBytes: 3_000
        ))
        let second = try XCTUnwrap(ProductEvidenceMediaSample(
            role: .receiver,
            sequence: 2,
            elapsedMilliseconds: 31_000,
            videoFrames: 40,
            videoBytes: 4_000,
            audioUnits: 50,
            audioBytes: 5_000
        ))
        XCTAssertTrue(recorder.recordWebRTCMediaSample(owner: owner, sample: first))
        XCTAssertFalse(recorder.recordWebRTCMediaSample(owner: owner, sample: stale))
        XCTAssertTrue(recorder.recordWebRTCMediaSample(owner: owner, sample: second))
        XCTAssertTrue(recorder.endSession(owner: owner, reason: .peer))
        XCTAssertEqual(lines.filter { $0.hasPrefix("webrtcMediaSample ") }.count, 2)
    }

    private func signedClassicOffer(
        attemptByte: UInt8,
        signingKey: Curve25519.Signing.PrivateKey = .init(),
        identity: SkyBridgeCompass_iOS.IdentityPublicKeys? = nil
    ) throws -> SkyBridgeCompass_iOS.HandshakeMessageA {
        let identity = identity ?? SkyBridgeCompass_iOS.IdentityPublicKeys(
            protocolPublicKey: signingKey.publicKey.rawRepresentation,
            protocolAlgorithm: .ed25519
        )
        let soa = try SkyBridgeCompass_iOS.HandshakeSOAExtension(
            initiatorPeerId: Data(repeating: 0x81, count: 32),
            targetPeerId: Data(repeating: 0x82, count: 32),
            attemptId: Data(repeating: attemptByte, count: 16)
        )
        let unsigned = SkyBridgeCompass_iOS.HandshakeMessageA(
            supportedSuites: [.x25519Ed25519],
            keyShares: [
                SkyBridgeCompass_iOS.HandshakeKeyShare(
                    suite: .x25519Ed25519,
                    shareBytes: Data(repeating: 0x83, count: 32)
                )
            ],
            clientNonce: Data(repeating: 0x84, count: 32),
            policy: .init(
                requirePQC: false,
                allowClassicFallback: false,
                minimumTier: .classic
            ),
            capabilities: SkyBridgeCompass_iOS.CryptoCapabilities(
                supportedKEM: ["X25519"],
                supportedSignature: ["Ed25519"],
                supportedAuthProfiles: ["Classic"],
                supportedAEAD: ["AES-GCM-256"],
                pqcAvailable: false,
                platformVersion: "test",
                providerType: .classic
            ),
            signature: Data(),
            identityPublicKeys: identity,
            extensionsRaw: soa.encodedTLV
        )
        return SkyBridgeCompass_iOS.HandshakeMessageA(
            supportedSuites: unsigned.supportedSuites,
            keyShares: unsigned.keyShares,
            clientNonce: unsigned.clientNonce,
            policy: unsigned.policy,
            capabilities: unsigned.capabilities,
            signature: try signingKey.signature(for: unsigned.signaturePreimage),
            identityPublicKeys: identity,
            extensionsRaw: unsigned.extensionsRaw
        )
    }
}
