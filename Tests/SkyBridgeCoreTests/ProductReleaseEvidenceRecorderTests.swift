import XCTest
import CryptoKit
@_spi(RemoteControlSecurityNoticeUI) @testable import SkyBridgeCore
import SkyBridgeProtocolCore

@MainActor
final class ProductReleaseEvidenceRecorderTests: XCTestCase {
    private let sessionReference = "ev1:0123456789abcdef0123456789abcdef"

    func testSameReferenceRestartRejectsStaleOwnerWithoutEmitting() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }

        let first = try XCTUnwrap(recorder.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: sessionReference,
            routeClass: .wifi
        ))
        XCTAssertTrue(recorder.endSession(owner: first, reason: .peer))

        let second = try XCTUnwrap(recorder.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: sessionReference,
            routeClass: .wifi
        ))
        XCTAssertNotEqual(first, second)
        let lineCountBeforeStaleCallback = lines.count
        XCTAssertFalse(recorder.recordPeerFramePresented(
            owner: first,
            proof: .p2pRendererAcknowledgement,
            bytes: 512,
            width: 32,
            height: 16
        ))
        XCTAssertEqual(lines.count, lineCountBeforeStaleCallback)
        XCTAssertTrue(recorder.recordNoticeShown(owner: second))
        XCTAssertTrue(recorder.recordPendingNoticePanelPresented(owner: second))
        XCTAssertTrue(recorder.recordNoticeHumanApproved(owner: second))
        XCTAssertTrue(recorder.recordNoticeApproved(owner: second))
        XCTAssertTrue(recorder.recordNoticeActive(owner: second))
        XCTAssertTrue(recorder.recordPeerFramePresented(
            owner: second,
            proof: .p2pRendererAcknowledgement,
            bytes: 512,
            width: 32,
            height: 16
        ))

        XCTAssertEqual(lines.filter { $0.hasPrefix("releaseSessionOwner ") }.count, 2)
        XCTAssertEqual(lines.filter { $0.hasPrefix("secureFrameAccepted ") }.count, 1)
        XCTAssertTrue(lines.last?.contains("effect=presented") == true)
        XCTAssertTrue(lines.last?.contains("generation=2") == true)
    }

    func testOldNoticeDescriptorCallbackCannotWriteReplacementOwner() async throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let firstOwner = try XCTUnwrap(recorder.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: sessionReference,
            routeClass: .wifi
        ))
        let center = RemoteControlSecurityNoticeCenter(productEvidenceRecorder: recorder)
        let oldDescriptor = makeDescriptor(id: UUID())
        let oldApproval = Task { @MainActor in
            await center.requestApproval(oldDescriptor)
        }
        await Task.yield()
        center.recordPanelPresentedEvidence(
            descriptor: oldDescriptor,
            phase: .awaitingApproval,
            frame: "0,0,600,180",
            visibleFrame: "0,0,1200,800",
            windowLevel: "statusBar",
            collectionBehavior: ["canJoinAllSpaces"],
            buttons: ["approve", "reject"],
            topCentered: true
        )

        XCTAssertTrue(recorder.endSession(owner: firstOwner, reason: .sessionReplaced))
        let replacementOwner = try XCTUnwrap(recorder.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: sessionReference,
            routeClass: .wifi
        ))
        XCTAssertNotEqual(firstOwner, replacementOwner)
        let beforeOldCallbacks = lines.count
        center.approveNoticeFromUserInteraction(id: oldDescriptor.id)
        center.recordPanelHiddenEvidence(
            descriptor: oldDescriptor,
            phase: .active
        )
        XCTAssertEqual(
            lines.dropFirst(beforeOldCallbacks).filter { $0.contains("generation=2") }.count,
            0
        )
        XCTAssertFalse(lines.contains {
            $0.hasPrefix("remoteControlNoticeHumanApproved ") && $0.contains("generation=2")
        })
        XCTAssertFalse(lines.contains {
            $0.hasPrefix("remoteControlNoticePanelHidden ") && $0.contains("generation=2")
        })
        let oldDecision = await oldApproval.value
        XCTAssertEqual(oldDecision, .approved)
    }

    func testNoticeLifecycleRequiresRealPanelAndSingleTerminal() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let owner = try XCTUnwrap(recorder.beginSession(
            product: .macOSApp,
            transport: .webrtc,
            sessionReference: sessionReference,
            selectedTransport: .relay
        ))

        XCTAssertFalse(recorder.recordPendingNoticePanelPresented(owner: owner))
        XCTAssertFalse(recorder.recordNoticeHumanApproved(owner: owner))
        XCTAssertFalse(recorder.recordNoticePanelHidden(owner: owner))
        XCTAssertFalse(recorder.recordNoticeTerminated(owner: owner, result: .rejected))
        XCTAssertFalse(recorder.recordPeerFramePresented(
            owner: owner,
            proof: .p2pRendererAcknowledgement,
            bytes: 128,
            width: 8,
            height: 8
        ))
        XCTAssertFalse(recorder.recordRemoteInputApplied(owner: owner, effect: .keyboard))
        XCTAssertTrue(recorder.recordNoticeShown(owner: owner))
        XCTAssertTrue(recorder.recordPendingNoticePanelPresented(owner: owner))
        XCTAssertTrue(recorder.recordNoticeHumanApproved(owner: owner))
        XCTAssertTrue(recorder.recordNoticeApproved(owner: owner))
        XCTAssertTrue(recorder.recordNoticeActive(owner: owner))
        XCTAssertTrue(recorder.recordNoticeTerminated(owner: owner, result: .disconnected))
        XCTAssertFalse(recorder.recordNoticeTerminated(owner: owner, result: .rejected))
        XCTAssertFalse(recorder.recordNoticeApproved(owner: owner))
        XCTAssertFalse(recorder.recordRemoteInputApplied(owner: owner, effect: .keyboard))

        XCTAssertTrue(recorder.endSession(owner: owner, reason: .user))
        XCTAssertFalse(lines.contains { $0.hasPrefix("releaseSessionDisconnected ") })
        XCTAssertTrue(recorder.recordNoticePanelHidden(owner: owner))
        XCTAssertEqual(lines.filter { $0.hasPrefix("releaseSessionDisconnected ") }.count, 1)
        XCTAssertTrue(lines.last?.contains("noticeHidden=1") == true)
    }

    func testEffectEvidenceIsBoundedAndContainsNoRawSensitiveFields() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let owner = try XCTUnwrap(recorder.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: sessionReference,
            routeClass: .awdl
        ))
        XCTAssertTrue(recorder.recordNoticeShown(owner: owner))
        XCTAssertTrue(recorder.recordPendingNoticePanelPresented(owner: owner))
        XCTAssertTrue(recorder.recordNoticeHumanApproved(owner: owner))
        XCTAssertTrue(recorder.recordNoticeApproved(owner: owner))
        XCTAssertTrue(recorder.recordNoticeActive(owner: owner))

        XCTAssertTrue(recorder.recordPeerFramePresented(
            owner: owner,
            proof: .p2pRendererAcknowledgement,
            bytes: 4_096,
            width: 640,
            height: 480
        ))
        XCTAssertFalse(recorder.recordPeerFramePresented(
            owner: owner,
            proof: .p2pRendererAcknowledgement,
            bytes: 8_192,
            width: 1_280,
            height: 720
        ))
        XCTAssertTrue(recorder.recordRemoteInputApplied(owner: owner, effect: .pointer))
        XCTAssertFalse(recorder.recordRemoteInputApplied(owner: owner, effect: .pointer))
        XCTAssertTrue(recorder.recordRemoteInputApplied(owner: owner, effect: .keyboard))

        let output = lines.joined(separator: "\n")
        XCTAssertTrue(output.contains("frame_seq=1"))
        XCTAssertTrue(output.contains("event_seq=2"))
        XCTAssertTrue(output.contains("event_seq=3"))
        for forbiddenKey in [
            "session=", "remoteIP=", "device=", "account=", "keyCode=",
            "x=", "y=", "path=", "fileName=", "payload=", "token=", "sas="
        ] {
            XCTAssertFalse(output.contains(forbiddenKey), "Unexpected sensitive key: \(forbiddenKey)")
        }
    }

    func testConnectivityEndpointRecordsOnlyTheLocalActualProfile() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let attemptReference = try XCTUnwrap(
            ProductConnectivityAttemptReference.make(from: Data(repeating: 0x2a, count: 16))
        )
        let owner = try XCTUnwrap(recorder.beginConnectivityAttempt(
            attemptReference: attemptReference,
            role: .initiator,
            localProfile: .xwing,
            offeredSuites: [.xwingMLDSA, .mlkem768MLDSA65],
            requirePQC: true,
            allowClassicFallback: false
        ))
        XCTAssertTrue(recorder.authenticateConnectivityAttempt(
            owner: owner,
            sessionReference: sessionReference,
            negotiatedSuite: .mlkem768MLDSA65
        ))
        XCTAssertFalse(recorder.authenticateConnectivityAttempt(
            owner: owner,
            sessionReference: sessionReference,
            negotiatedSuite: .mlkem768MLDSA65
        ))

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("connectivityEndpoint ") }.count,
            1
        )
        let endpoint = try XCTUnwrap(lines.last)
        XCTAssertTrue(endpoint.contains("session_ref=\(sessionReference)"))
        XCTAssertTrue(endpoint.contains("attempt_ref=\(attemptReference)"))
        XCTAssertTrue(endpoint.contains("generation=1"))
        XCTAssertTrue(endpoint.contains("localProfile=xwing"))
        XCTAssertTrue(endpoint.contains("offeredProfiles=pqc+xwing"))
        XCTAssertTrue(endpoint.contains("attemptProfile=pqc"))
        XCTAssertTrue(endpoint.contains("suite=ML-KEM-768"))
        XCTAssertFalse(endpoint.contains("peerProfile="))
        XCTAssertFalse(endpoint.contains("responderProfile="))
    }

    func testClassicMatrixEdgesAreExpectedPolicyRejectionsNotSuccessSessions() async throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let firstOffer = try signedClassicOffer(attemptByte: 0x11)
        let acceptedFirst = await recorder.recordStrictPQCClassicOfferRejection(
            peerMessageA: firstOffer,
            localProfile: .pqc,
            offeredSuites: [.mlkem768MLDSA65, .xwingMLDSA]
        )
        XCTAssertTrue(acceptedFirst)
        let acceptedDuplicate = await recorder.recordStrictPQCClassicOfferRejection(
            peerMessageA: firstOffer,
            localProfile: .pqc,
            offeredSuites: [.mlkem768MLDSA65, .xwingMLDSA]
        )
        XCTAssertFalse(acceptedDuplicate)

        let acceptedSecond = await recorder.recordStrictPQCClassicOfferRejection(
            peerMessageA: try signedClassicOffer(attemptByte: 0x22),
            localProfile: .xwing,
            offeredSuites: [.xwingMLDSA, .mlkem768MLDSA65]
        )
        XCTAssertTrue(acceptedSecond)

        XCTAssertEqual(lines.filter { $0.hasPrefix("connectivityPolicyRejected ") }.count, 2)
        XCTAssertFalse(lines.contains { $0.hasPrefix("connectivityEndpoint ") })
        XCTAssertTrue(lines.contains {
            $0.contains("peerOfferSignature=verified")
                && $0.contains("reason=strict-pqc-rejects-classic result=rejected")
        })
    }

    func testConnectivityAttemptReferencesAndProfilesFailClosed() {
        XCTAssertEqual(
            ProductConnectivityAttemptReference.make(from: Data(repeating: 0xab, count: 16)),
            "at1:abababababababababababababababab"
        )
        XCTAssertNil(ProductConnectivityAttemptReference.make(from: Data(repeating: 0, count: 15)))
        XCTAssertEqual(
            ProductIdentityEvidenceReference.make(
                fromAuthoritativeFingerprint: String(repeating: "ab", count: 32)
            ),
            "id1:abababababababababababababababab"
        )
        XCTAssertNil(ProductIdentityEvidenceReference.make(
            fromAuthoritativeFingerprint: String(repeating: "A", count: 64)
        ))
        XCTAssertNil(ProductIdentityEvidenceReference.make(
            fromAuthoritativeFingerprint: String(repeating: "a", count: 63)
        ))
        XCTAssertTrue(ProductIdentityEvidenceDescriptor(
            identityReference: "id1:abababababababababababababababab",
            algorithm: .mlDSA87,
            protection: .secureEnclaveRequired
        )?.isFormalProductionIdentity == true)
        XCTAssertEqual(
            ProductConnectivityProfileClassifier.configuredProfile(
                requirePQC: true,
                selectedSuiteWireID: CryptoSuite.xwingMLDSA.wireId
            ),
            .xwing
        )
        XCTAssertEqual(
            ProductConnectivityProfileClassifier.configuredProfile(
                requirePQC: true,
                selectedSuiteWireID: CryptoSuite.mlkem768MLDSA65.wireId
            ),
            .pqc
        )
        XCTAssertEqual(
            ProductConnectivityProfileClassifier.configuredProfile(
                requirePQC: false,
                selectedSuiteWireID: CryptoSuite.x25519Ed25519.wireId
            ),
            .classic
        )
        XCTAssertEqual(ProductConnectivityProfileClassifier.offeredProfiles(
            suiteWireIDs: [
                CryptoSuite.xwingMLDSA.wireId,
                CryptoSuite.mlkem768MLDSA65.wireId
            ]
        ), .pqcAndXWing)
        XCTAssertNil(ProductConnectivityProfileClassifier.offeredProfiles(
            suiteWireIDs: [
                CryptoSuite.x25519Ed25519.wireId,
                CryptoSuite.mlkem768MLDSA65.wireId
            ]
        ))

        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        XCTAssertNil(recorder.beginConnectivityAttempt(
            attemptReference: "raw-attempt",
            role: .initiator,
            localProfile: .pqc,
            offeredSuites: [.mlkem768MLDSA65],
            requirePQC: true,
            allowClassicFallback: false
        ))
        XCTAssertNil(recorder.beginConnectivityAttempt(
            attemptReference: "at1:33333333333333333333333333333333",
            role: .initiator,
            localProfile: .classic,
            offeredSuites: [.x25519Ed25519],
            requirePQC: true,
            allowClassicFallback: false
        ))
        XCTAssertNil(recorder.beginConnectivityAttempt(
            attemptReference: "at1:34343434343434343434343434343434",
            role: .initiator,
            localProfile: .xwing,
            offeredSuites: [.mlkem768MLDSA65],
            requirePQC: true,
            allowClassicFallback: false
        ))
        XCTAssertNil(recorder.beginConnectivityAttempt(
            attemptReference: "at1:35353535353535353535353535353535",
            role: .initiator,
            localProfile: .pqc,
            offeredSuites: [.xwingMLDSA],
            requirePQC: true,
            allowClassicFallback: false
        ))
        XCTAssertTrue(lines.isEmpty)
    }

    func testAuthenticatedSuiteMustHaveBeenInTheExactLocalOffer() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let owner = try XCTUnwrap(recorder.beginConnectivityAttempt(
            attemptReference: "at1:44444444444444444444444444444444",
            role: .initiator,
            localProfile: .pqc,
            offeredSuites: [.mlkem768MLDSA65],
            requirePQC: true,
            allowClassicFallback: false
        ))

        XCTAssertFalse(recorder.authenticateConnectivityAttempt(
            owner: owner,
            sessionReference: sessionReference,
            negotiatedSuite: .xwingMLDSA
        ))
        XCTAssertTrue(recorder.failConnectivityAttempt(
            owner: owner,
            reason: .publicationFailed
        ))
        XCTAssertFalse(lines.contains { $0.hasPrefix("connectivityEndpoint ") })
    }

    func testPolicyRejectionRequiresARealHomogeneousPeerOffer() async throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let acceptedMixed = await recorder.recordStrictPQCClassicOfferRejection(
            peerMessageA: try signedOffer(
                suites: [.x25519Ed25519, .mlkem768MLDSA65],
                attemptByte: 0x55
            ),
            localProfile: .pqc,
            offeredSuites: [.mlkem768MLDSA65, .xwingMLDSA]
        )
        XCTAssertFalse(acceptedMixed)
        let acceptedClassic = await recorder.recordStrictPQCClassicOfferRejection(
            peerMessageA: try signedClassicOffer(attemptByte: 0x55),
            localProfile: .pqc,
            offeredSuites: [.mlkem768MLDSA65, .xwingMLDSA]
        )
        XCTAssertTrue(acceptedClassic)
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("connectivityPolicyRejected ") }.count,
            1
        )
    }

    func testClassicRejectionOfferMustHaveAValidProtocolSignature() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signed = try signedClassicOffer(
            attemptByte: 0x66,
            signingKey: privateKey
        )
        var validLines: [String] = []
        let validRecorder = ProductReleaseEvidenceRecorder { validLines.append($0) }
        let acceptedValid = await validRecorder.recordStrictPQCClassicOfferRejection(
            peerMessageA: signed,
            localProfile: .pqc,
            offeredSuites: [.mlkem768MLDSA65]
        )
        XCTAssertTrue(acceptedValid)
        let acceptedReplay = await validRecorder.recordStrictPQCClassicOfferRejection(
            peerMessageA: signed,
            localProfile: .pqc,
            offeredSuites: [.mlkem768MLDSA65]
        )
        XCTAssertFalse(acceptedReplay)
        XCTAssertEqual(validLines.count, 2)

        let invalidSignature = HandshakeMessageA(
            supportedSuites: signed.supportedSuites,
            keyShares: signed.keyShares,
            clientNonce: signed.clientNonce,
            policy: signed.policy,
            capabilities: signed.capabilities,
            signature: Data(repeating: 0, count: signed.signature.count),
            identityPublicKey: signed.identityPublicKey,
            extensionsRaw: signed.extensionsRaw
        )
        let tamperedSuite = HandshakeMessageA(
            supportedSuites: [.mlkem768MLDSA65],
            keyShares: signed.keyShares,
            clientNonce: signed.clientNonce,
            policy: signed.policy,
            capabilities: signed.capabilities,
            signature: signed.signature,
            identityPublicKey: signed.identityPublicKey,
            extensionsRaw: signed.extensionsRaw
        )
        let tamperedPolicy = HandshakeMessageA(
            supportedSuites: signed.supportedSuites,
            keyShares: signed.keyShares,
            clientNonce: signed.clientNonce,
            policy: .strictPQC,
            capabilities: signed.capabilities,
            signature: signed.signature,
            identityPublicKey: signed.identityPublicKey,
            extensionsRaw: signed.extensionsRaw
        )
        let changedSOA = try HandshakeSOAExtension(
            initiatorPeerId: Data(repeating: 0x91, count: 32),
            targetPeerId: Data(repeating: 0x92, count: 32),
            attemptId: Data(repeating: 0x67, count: 16)
        )
        let tamperedAttempt = HandshakeMessageA(
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
        let wrongIdentity = IdentityPublicKeys(
            protocolPublicKey: wrongIdentityKey.publicKey.rawRepresentation,
            protocolAlgorithm: .ed25519
        )
        let signedByWrongKey = try signedClassicOffer(
            attemptByte: 0x68,
            signingKey: privateKey,
            identity: wrongIdentity
        )

        for rejectedMessage in [
            invalidSignature, tamperedSuite, tamperedPolicy,
            tamperedAttempt, signedByWrongKey
        ] {
            var rejectedLines: [String] = []
            let recorder = ProductReleaseEvidenceRecorder { rejectedLines.append($0) }
            let accepted = await recorder.recordStrictPQCClassicOfferRejection(
                peerMessageA: rejectedMessage,
                localProfile: .pqc,
                offeredSuites: [.mlkem768MLDSA65]
            )
            XCTAssertFalse(accepted)
            XCTAssertTrue(rejectedLines.isEmpty)
        }
    }

    func testConcurrentClassicOfferReplayEmitsOneTerminalPair() async throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let offer = try signedClassicOffer(attemptByte: 0x69)

        let first = Task { @MainActor in
            await recorder.recordStrictPQCClassicOfferRejection(
                peerMessageA: offer,
                localProfile: .pqc,
                offeredSuites: [.mlkem768MLDSA65]
            )
        }
        let second = Task { @MainActor in
            await recorder.recordStrictPQCClassicOfferRejection(
                peerMessageA: offer,
                localProfile: .pqc,
                offeredSuites: [.mlkem768MLDSA65]
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
            .maximumRetainedConnectivityRejectionCount {
            let accepted = await recorder.recordStrictPQCClassicOfferRejection(
                peerMessageA: try signedClassicOffer(attemptByte: UInt8(index)),
                localProfile: .pqc,
                offeredSuites: [.mlkem768MLDSA65]
            )
            XCTAssertTrue(accepted)
        }
        let overflowAccepted = await recorder.recordStrictPQCClassicOfferRejection(
            peerMessageA: try signedClassicOffer(attemptByte: 0xfe),
            localProfile: .pqc,
            offeredSuites: [.mlkem768MLDSA65]
        )

        XCTAssertFalse(overflowAccepted)
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("connectivityPolicyRejected ") }.count,
            ProductReleaseEvidenceRecorder.maximumRetainedConnectivityRejectionCount
        )
    }

    func testInvalidOwnerInputsFailClosedWithoutEvidence() {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }

        XCTAssertNil(recorder.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: "raw-session-id",
            routeClass: .wifi
        ))
        XCTAssertNil(recorder.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: sessionReference,
            selectedTransport: .direct
        ))
        XCTAssertNil(recorder.beginSession(
            product: .macOSApp,
            transport: .webrtc,
            sessionReference: sessionReference,
            routeClass: .wifi
        ))
        XCTAssertTrue(lines.isEmpty)
    }

    func testRetainedSessionStateHasFailClosedCapacityBound() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        for offset in 0..<ProductReleaseEvidenceRecorder.maximumRetainedSessionCount {
            XCTAssertNotNil(recorder.beginSession(
                product: .macOSApp,
                transport: .p2p,
                sessionReference: String(format: "ev1:%032x", offset + 1),
                routeClass: .wifi
            ))
        }
        let lineCountAtCapacity = lines.count
        XCTAssertNil(recorder.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: "ev1:ffffffffffffffffffffffffffffffff",
            routeClass: .wifi
        ))
        XCTAssertEqual(lines.count, lineCountAtCapacity)
    }

    func testSessionEvidenceHasHardLineCountBound() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let owner = try XCTUnwrap(recorder.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: sessionReference,
            routeClass: .wifi
        ))
        XCTAssertTrue(recorder.recordNoticeShown(owner: owner))
        XCTAssertTrue(recorder.recordPendingNoticePanelPresented(owner: owner))
        XCTAssertTrue(recorder.recordNoticeHumanApproved(owner: owner))
        XCTAssertTrue(recorder.recordNoticeApproved(owner: owner))
        XCTAssertTrue(recorder.recordNoticeActive(owner: owner))
        XCTAssertTrue(recorder.recordPeerFramePresented(
            owner: owner,
            proof: .p2pRendererAcknowledgement,
            bytes: 1_024,
            width: 64,
            height: 64
        ))
        for _ in 0..<1_000 {
            _ = recorder.recordPeerFramePresented(
                owner: owner,
                proof: .p2pRendererAcknowledgement,
                bytes: 1_024,
                width: 64,
                height: 64
            )
            _ = recorder.recordRemoteInputApplied(owner: owner, effect: .pointer)
            _ = recorder.recordRemoteInputApplied(owner: owner, effect: .keyboard)
            _ = recorder.recordRemoteInputApplied(owner: owner, effect: .scroll)
        }
        XCTAssertTrue(recorder.recordFileTransferStarted(
            owner: owner,
            transferReference: "ev1:abcdefabcdefabcdefabcdefabcdefab",
            direction: .receive
        ))
        XCTAssertTrue(recorder.recordFileTransferCompleted(
            owner: owner,
            transferReference: "ev1:abcdefabcdefabcdefabcdefabcdefab",
            direction: .receive,
            uiEffectVisible: true
        ))
        XCTAssertTrue(recorder.recordNoticeTerminated(owner: owner, result: .disconnected))
        XCTAssertTrue(recorder.endSession(owner: owner, reason: .user))
        XCTAssertTrue(recorder.recordNoticePanelHidden(owner: owner))
        XCTAssertLessThanOrEqual(
            lines.count,
            ProductReleaseEvidenceRecorder.maximumEvidenceLineCountPerSession
        )
        XCTAssertFalse(lines.contains { $0.hasPrefix("fileChunkAccepted ") })
    }

    func testP2PAuthenticationAndFileCompletionUseFixedPrivacySafeSchema() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let owner = try XCTUnwrap(recorder.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: sessionReference,
            routeClass: .awdl
        ))
        XCTAssertFalse(recorder.recordP2PSessionAuthenticated(
            owner: owner,
            role: .initiator,
            negotiatedSuite: .mlkem768MLDSA65
        ))
        XCTAssertTrue(recorder.recordP2PSessionAuthenticated(
            owner: owner,
            role: .initiator,
            negotiatedSuite: .xwingMLDSA
        ))
        let transferReference = "ev1:abcdefabcdefabcdefabcdefabcdefab"
        XCTAssertTrue(recorder.recordFileTransferStarted(
            owner: owner,
            transferReference: transferReference,
            direction: .send
        ))
        XCTAssertTrue(recorder.recordFileTransferCompleted(
            owner: owner,
            transferReference: transferReference,
            direction: .send,
            uiEffectVisible: true
        ))
        XCTAssertTrue(recorder.endSession(owner: owner, reason: .user))

        XCTAssertTrue(lines.contains {
            $0.hasPrefix("p2pSessionAuthenticated ")
                && $0.contains("role=initiator suite=X-Wing result=authenticated")
        })
        XCTAssertTrue(lines.contains {
            $0.hasPrefix("fileTransferStarted ")
                && $0.contains("interaction=send-ui payload=nonempty result=started")
        })
        XCTAssertTrue(lines.contains {
            $0.hasPrefix("fileTransferCompleted ")
                && $0.contains("integrity=verified receipt=authenticated")
                && $0.contains("uiEffect=completed")
        })
        XCTAssertTrue(lines.last?.contains("noticeHidden=not-applicable") == true)
        let output = lines.joined(separator: "\n")
        for forbidden in ["fileName=", "filePath=", "exactBytes=", "deviceId="] {
            XCTAssertFalse(output.contains(forbidden))
        }
    }

    func testWebRTCMediaEvidenceRequiresXWingAndStrictlyIncreasingRealCounters() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let owner = try XCTUnwrap(recorder.beginSession(
            product: .macOSApp,
            transport: .webrtc,
            sessionReference: sessionReference,
            selectedTransport: .relay
        ))
        XCTAssertFalse(recorder.recordWebRTCPQCRekeyAuthenticated(
            owner: owner,
            negotiatedSuite: .mlkem768MLDSA65
        ))
        XCTAssertTrue(recorder.recordWebRTCPQCRekeyAuthenticated(
            owner: owner,
            negotiatedSuite: .xwingMLDSA
        ))
        let startedAt = ContinuousClock.now
        XCTAssertFalse(recorder.recordWebRTCMediaSample(
            owner: owner,
            role: .sender,
            counters: .init(videoFrames: 1, videoBytes: 1, audioUnits: 0, audioBytes: 1),
            now: startedAt
        ))
        XCTAssertTrue(recorder.recordWebRTCMediaSample(
            owner: owner,
            role: .sender,
            counters: .init(videoFrames: 60, videoBytes: 65_536, audioUnits: 100, audioBytes: 8_192),
            now: startedAt
        ))
        XCTAssertFalse(recorder.recordWebRTCMediaSample(
            owner: owner,
            role: .sender,
            counters: .init(videoFrames: 60, videoBytes: 70_000, audioUnits: 110, audioBytes: 9_000),
            now: startedAt.advanced(by: .seconds(31))
        ))
        XCTAssertTrue(recorder.recordWebRTCMediaSample(
            owner: owner,
            role: .sender,
            counters: .init(videoFrames: 1_920, videoBytes: 2_097_152, audioUnits: 3_200, audioBytes: 262_144),
            now: startedAt.advanced(by: .seconds(31))
        ))
        XCTAssertEqual(lines.filter { $0.hasPrefix("webrtcMediaSample ") }.count, 2)
        XCTAssertTrue(lines.last?.contains("sample_seq=2 elapsed_ms=31000") == true)
    }

    func testLocalPresentationCannotOccupyOrImpersonatePeerRendererProof() throws {
        var lines: [String] = []
        let recorder = ProductReleaseEvidenceRecorder { lines.append($0) }
        let owner = try XCTUnwrap(recorder.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: sessionReference,
            routeClass: .wifi
        ))
        XCTAssertTrue(recorder.recordNoticeShown(owner: owner))
        XCTAssertTrue(recorder.recordPendingNoticePanelPresented(owner: owner))
        XCTAssertTrue(recorder.recordNoticeHumanApproved(owner: owner))
        XCTAssertTrue(recorder.recordNoticeApproved(owner: owner))
        XCTAssertTrue(recorder.recordNoticeActive(owner: owner))

        XCTAssertTrue(recorder.recordLocalFramePresented(
            owner: owner,
            bytes: 1_024,
            width: 64,
            height: 64
        ))
        XCTAssertFalse(recorder.recordPeerFramePresented(
            owner: owner,
            proof: .webrtcRendererReceipt,
            bytes: 1_024,
            width: 64,
            height: 64
        ))
        XCTAssertTrue(recorder.recordPeerFramePresented(
            owner: owner,
            proof: .p2pRendererAcknowledgement,
            bytes: 1_024,
            width: 64,
            height: 64
        ))

        XCTAssertEqual(lines.filter { $0.hasPrefix("localFramePresented ") }.count, 1)
        XCTAssertEqual(lines.filter { $0.hasPrefix("secureFrameAccepted ") }.count, 1)
        XCTAssertTrue(lines.contains {
            $0.hasPrefix("localFramePresented ")
                && $0.contains("proof=local-renderer")
        })
        XCTAssertTrue(lines.contains {
            $0.hasPrefix("secureFrameAccepted ")
                && $0.contains("proof=p2p-renderer-ack")
        })
    }

    func testShippingSourceContractHasNoHiddenTriggerPersistenceOrHashExpansion() throws {
        let recorderSource = try source(
            "Sources/SkyBridgeCore/Diagnostics/ProductReleaseEvidenceRecorder.swift"
        )
        XCTAssertTrue(recorderSource.contains(
            "subsystem: \"com.skybridge.compass.release-evidence\""
        ))
        XCTAssertTrue(recorderSource.contains("category: \"ProductSession\""))
        XCTAssertTrue(recorderSource.contains("isValidClassicOnlyOffer(peerMessageA)"))
        XCTAssertTrue(recorderSource.contains("product: .macOSApp"))
        XCTAssertFalse(recorderSource.contains(
            "beginConnectivityAttempt(\n        product:"
        ))
        XCTAssertFalse(recorderSource.contains("peerOfferedSuites:"))
        for forbidden in [
            "ProcessInfo.processInfo.environment", "UserDefaults", "FileManager",
            "SHA256", "CryptoKit", "fileChunkAccepted"
        ] {
            XCTAssertFalse(recorderSource.contains(forbidden), "Forbidden shipping surface: \(forbidden)")
        }

        let connectivitySource = try source(
            "Sources/SkyBridgeProtocolCore/P2P/ProductConnectivityEvidence.swift"
        )
        for forbidden in [
            "ProcessInfo.processInfo.environment", "UserDefaults", "FileManager",
            "SHA256", "CryptoKit", "peerProfile=", "responderProfile="
        ] {
            XCTAssertFalse(
                connectivitySource.contains(forbidden),
                "Forbidden connectivity evidence surface: \(forbidden)"
            )
        }
        XCTAssertTrue(connectivitySource.contains("case pqcAndXWing = \"pqc+xwing\""))
        XCTAssertTrue(connectivitySource.contains("\"offeredProfiles=\\(owner.offeredProfiles.rawValue)\""))
        XCTAssertTrue(connectivitySource.contains("owner.offeredSuiteWireIDs.contains"))

        let outboundP2PSource = try source("Sources/SkyBridgeCore/P2P/P2PModels.swift")
        XCTAssertTrue(outboundP2PSource.contains("from: outboundSOA.attemptId"))
        XCTAssertTrue(outboundP2PSource.contains("offeredSuites: preparation.offeredSuites"))
        XCTAssertTrue(outboundP2PSource.contains(
            "selectedSuiteWireID: cryptoProvider.activeSuite.wireId"
        ))
        XCTAssertTrue(outboundP2PSource.contains("P2PEvidenceReference.sessionIncarnation("))

        let inboundP2PSource = try source(
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
        )
        XCTAssertTrue(inboundP2PSource.contains("messageA.soaExtension.flatMap"))
        XCTAssertTrue(inboundP2PSource.contains("peerMessageA: messageA"))
        XCTAssertTrue(inboundP2PSource.contains("recordStrictPQCClassicOfferRejection"))
        XCTAssertTrue(inboundP2PSource.contains("productConnectivityAttemptSnapshot()"))
        XCTAssertTrue(inboundP2PSource.contains("offeredSuites: attemptSnapshot.localOfferedSuites"))
        XCTAssertTrue(inboundP2PSource.contains("await authenticateProductConnectivityAttemptIfReady"))

        let signedOfferVerifierSource = try source(
            "Sources/SkyBridgeCore/P2P/ProductConnectivitySignedOfferVerifier.swift"
        )
        XCTAssertTrue(signedOfferVerifierSource.contains("messageA.signaturePreimage"))
        XCTAssertTrue(signedOfferVerifierSource.contains("identity.protocolAlgorithm == .ed25519"))
        XCTAssertFalse(signedOfferVerifierSource.contains("try!"))

        let iOSRecorderSource = try source(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Diagnostics/ProductReleaseEvidenceRecorder.swift"
        )
        XCTAssertTrue(iOSRecorderSource.contains("product: .iOSApp"))
        XCTAssertTrue(iOSRecorderSource.contains("isValidClassicOnlyOffer(peerMessageA)"))
        XCTAssertFalse(iOSRecorderSource.contains("peerOfferedSuites:"))
        for forbidden in ["ProcessInfo.processInfo.environment", "UserDefaults", "SHA256"] {
            XCTAssertFalse(iOSRecorderSource.contains(forbidden))
        }
        let iOSP2PSource = try source(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        XCTAssertTrue(iOSP2PSource.contains("messageA.soaExtension?.attemptId"))
        XCTAssertTrue(iOSP2PSource.contains("attemptSnapshot.outboundSOAAttemptID"))
        XCTAssertTrue(iOSP2PSource.contains("peerMessageA: messageA"))
        XCTAssertTrue(iOSP2PSource.contains("recordStrictPQCClassicOfferRejection"))
        XCTAssertTrue(iOSP2PSource.contains("P2PEvidenceReference.sessionIncarnation("))

        let panelSource = try source(
            "Sources/SkyBridgeUI/Security/RemoteControlSecurityNoticePanelController.swift"
        )
        let orderFront = try XCTUnwrap(panelSource.range(of: "orderFrontRegardless()"))
        let presented = try XCTUnwrap(
            panelSource.range(of: "recordPresentedEvidence(", range: orderFront.upperBound..<panelSource.endIndex)
        )
        XCTAssertLessThan(orderFront.lowerBound, presented.lowerBound)
        let orderOut = try XCTUnwrap(panelSource.range(of: "orderOut(nil)"))
        let hidden = try XCTUnwrap(
            panelSource.range(of: "recordPanelHiddenEvidence(", range: orderOut.upperBound..<panelSource.endIndex)
        )
        XCTAssertLessThan(orderOut.lowerBound, hidden.lowerBound)

        let fileManagerSource = try source(
            "Sources/SkyBridgeCore/FileTransfer/FileTransferManager.swift"
        )
        XCTAssertTrue(fileManagerSource.contains("exactSnapshot: ClassicTransferSessionSnapshot?"))
        XCTAssertTrue(fileManagerSource.contains("symmetricKeyMaterialEquals("))
        XCTAssertTrue(fileManagerSource.contains("recordProductFileTransferCompletionVisible("))
        let fileViewSource = try source(
            "Sources/SkyBridgeUI/FileTransfer/FileTransferView.swift"
        )
        XCTAssertTrue(fileViewSource.contains(".onAppear"))
        XCTAssertTrue(fileViewSource.contains("recordProductFileTransferCompletionVisible("))

        let webRTCSource = try source(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        XCTAssertTrue(webRTCSource.contains("configuration.nativeVideoTrackReady == true"))
        XCTAssertTrue(webRTCSource.contains("rtcStats.framesSent > 0"))
        XCTAssertTrue(webRTCSource.contains("recordWebRTCProductFrameIfRemoteRenderConfirmed("))
    }

    func testSharedSelectedICETransportClassifierFailsClosedAndDetectsRelay() {
        typealias Classifier = WebRTCSelectedICETransportPathClassifier
        let selected = Classifier.CandidatePair(
            isAuthoritySelected: true,
            localCandidateID: "local",
            remoteCandidateID: "remote"
        )
        XCTAssertEqual(
            Classifier.classify(
                candidatePairs: [selected],
                candidatesByID: [
                    "local": .init(candidateType: "host"),
                    "remote": .init(candidateType: "relay"),
                ]
            ),
            .relay
        )
        XCTAssertEqual(
            Classifier.classify(
                candidatePairs: [selected],
                candidatesByID: [
                    "local": .init(candidateType: "host"),
                    "remote": .init(candidateType: "srflx"),
                ]
            ),
            .direct
        )
        XCTAssertEqual(
            Classifier.classify(
                candidatePairs: [selected, selected],
                candidatesByID: [
                    "local": .init(candidateType: "host"),
                    "remote": .init(candidateType: "relay"),
                ]
            ),
            .unknown
        )
        XCTAssertEqual(
            Classifier.classify(
                candidatePairs: [selected],
                candidatesByID: ["local": .init(candidateType: "host")]
            ),
            .unknown
        )
    }

    private func makeDescriptor(id: UUID) -> RemoteControlSecurityDescriptor {
        RemoteControlSecurityDescriptor(
            id: id,
            sessionId: "raw-session-not-logged",
            sessionEvidenceReference: sessionReference,
            transportKind: .p2p,
            remoteIPAddress: "192.0.2.20",
            remoteDeviceId: "device-not-logged",
            remoteDeviceName: "Phone",
            remoteAccountDisplayName: "Account",
            remoteNebulaId: "Nebula",
            localAccountDisplayName: "Local",
            localNebulaId: "LocalNebula",
            cryptoSuite: "X-Wing PQC",
            approvalTimeoutSeconds: 120
        )
    }

    private func signedClassicOffer(
        attemptByte: UInt8,
        signingKey: Curve25519.Signing.PrivateKey = .init(),
        identity: IdentityPublicKeys? = nil
    ) throws -> HandshakeMessageA {
        try signedOffer(
            suites: [.x25519Ed25519],
            attemptByte: attemptByte,
            signingKey: signingKey,
            identity: identity
        )
    }

    private func signedOffer(
        suites: [CryptoSuite],
        attemptByte: UInt8,
        signingKey: Curve25519.Signing.PrivateKey = .init(),
        identity: IdentityPublicKeys? = nil
    ) throws -> HandshakeMessageA {
        let identity = identity ?? IdentityPublicKeys(
            protocolPublicKey: signingKey.publicKey.rawRepresentation,
            protocolAlgorithm: .ed25519
        )
        let soa = try HandshakeSOAExtension(
            initiatorPeerId: Data(repeating: 0x91, count: 32),
            targetPeerId: Data(repeating: 0x92, count: 32),
            attemptId: Data(repeating: attemptByte, count: 16)
        )
        let unsigned = HandshakeMessageA(
            supportedSuites: suites,
            keyShares: suites.map {
                HandshakeKeyShare(
                    suite: $0,
                    shareBytes: Data(repeating: 0x93, count: 32)
                )
            },
            clientNonce: Data(repeating: 0x94, count: 32),
            policy: .init(
                requirePQC: false,
                allowClassicFallback: false,
                minimumTier: .classic
            ),
            capabilities: CryptoCapabilities(
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
        return HandshakeMessageA(
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

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
