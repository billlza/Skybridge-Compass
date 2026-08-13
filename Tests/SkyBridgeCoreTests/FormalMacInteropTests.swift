import Foundation
import CryptoKit
import XCTest
@testable import SkyBridgeCore
@testable import SkyBridgeAppleTransport
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
final class FormalMacInteropTests: XCTestCase {
    private let runRef = String(repeating: "a", count: 64)
    private let androidToMacTransferID = "11111111-1111-4111-8111-111111111111"
    private let macToAndroidTransferID = "22222222-2222-4222-8222-222222222222"
    private let token = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJmb3JtYWwtaG9zdCJ9.c2lnbmF0dXJl"

    @MainActor
    func testSignalingDeliveryQueuePreservesBackendLifecycleAndPayloadOrder() async {
        let queue = SignalingMainActorDeliveryQueue()
        let recorder = FormalSignalingOrderRecorder()
        let delivered = expectation(description: "all signaling callbacks drained")
        let expected = ["a-payload", "b-lifecycle", "b-payload"]

        for (index, value) in expected.enumerated() {
            queue.enqueue { @MainActor in
                recorder.values.append(value)
                if index == expected.count - 1 { delivered.fulfill() }
            }
        }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(recorder.values, expected)
    }

    func testSignalingCloseRetiresHandleBeforeSuspendingAndStaleCallbacksReturn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeAppleTransport/RemoteConnection/WebRTC/WebSocketSignalingClient.swift"
            ),
            encoding: .utf8
        )
        let closeStart = try XCTUnwrap(source.range(of: "public func close() async"))
        let closeTail = source[closeStart.lowerBound...]
        let retire = try XCTUnwrap(closeTail.range(of: "beginCloseSequence()"))
        let firstAwait = try XCTUnwrap(closeTail.range(of: "await cleanupURLSessionTransport()"))
        XCTAssertLessThan(
            closeTail.distance(from: closeTail.startIndex, to: retire.lowerBound),
            closeTail.distance(from: closeTail.startIndex, to: firstAwait.lowerBound)
        )
        let beginStart = try XCTUnwrap(source.range(of: "private func beginCloseSequence()"))
        let beginTail = source[beginStart.lowerBound...]
        let clearHandle = try XCTUnwrap(beginTail.range(of: "currentHandle = nil"))
        let closingLifecycle = try XCTUnwrap(beginTail.range(of: "phase: .closing"))
        XCTAssertLessThan(
            beginTail.distance(from: beginTail.startIndex, to: clearHandle.lowerBound),
            beginTail.distance(from: beginTail.startIndex, to: closingLifecycle.lowerBound)
        )
        for handler in ["handleSocketOpen", "handleText", "handleClosed", "handleErrored"] {
            let handlerStart = try XCTUnwrap(source.range(of: "private func \(handler)"))
            let tail = source[handlerStart.lowerBound...]
            let guardRange = try XCTUnwrap(tail.range(of: "guard currentHandle == handleId else"))
            let deliveryCandidates = [
                tail.range(of: "onEnvelope?"),
                tail.range(of: "emitLifecycle("),
                tail.range(of: "isSocketOpen ="),
            ].compactMap { $0 }
            let firstDelivery = try XCTUnwrap(deliveryCandidates.min {
                tail.distance(from: tail.startIndex, to: $0.lowerBound) <
                    tail.distance(from: tail.startIndex, to: $1.lowerBound)
            })
            XCTAssertLessThan(
                tail.distance(from: tail.startIndex, to: guardRange.lowerBound),
                tail.distance(from: tail.startIndex, to: firstDelivery.lowerBound)
            )
        }
        let catchMarker = try XCTUnwrap(source.range(of: "lastError = error"))
        let catchTail = source[catchMarker.lowerBound...]
        let catchRevoke = try XCTUnwrap(catchTail.range(of: "currentHandle = nil"))
        let catchCleanup = try XCTUnwrap(catchTail.range(of: "await cleanupTransport(for: attempt.backend)"))
        XCTAssertLessThan(
            catchTail.distance(from: catchTail.startIndex, to: catchRevoke.lowerBound),
            catchTail.distance(from: catchTail.startIndex, to: catchCleanup.lowerBound)
        )
    }

    func testManagerRevalidatesSignalingClientAndGenerationAtMainActorDelivery() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
            ),
            encoding: .utf8
        )
        let callbackStart = try XCTUnwrap(source.range(of: "await newCandidate.setOnEnvelope"))
        let callbackTail = source[callbackStart.lowerBound...]
        let envelopeDelivery = try XCTUnwrap(callbackTail.range(of: "self.handleSignalingEnvelope(env)"))
        let serverDelivery = try XCTUnwrap(callbackTail.range(of: "self.handleSignalingServerFrame(frame)"))
        let requiredChecks = [
            "self.signalingClient === newCandidate",
            "self.activeSignalingHandle == handle",
            "handle.sessionId == sessionID",
            "env.sessionId == sessionID",
            "frame.sessionId == nil || frame.sessionId == sessionID",
        ]
        for check in requiredChecks {
            let range = try XCTUnwrap(callbackTail.range(of: check))
            XCTAssertLessThan(
                callbackTail.distance(from: callbackTail.startIndex, to: range.lowerBound),
                callbackTail.distance(
                    from: callbackTail.startIndex,
                    to: check.contains("frame") ? serverDelivery.lowerBound : envelopeDelivery.lowerBound
                )
            )
        }
    }

    func testCapabilityBindsCanonicalRunSessionAndTransferPayloads() throws {
        let capability = try makeCapability()
        let sessionRef = try capability.sessionRef("12345678-1234-1234-1234-1234567890ab")

        XCTAssertTrue(FormalMacInteropCapability.isCanonicalSHA256(sessionRef))
        XCTAssertEqual(
            capability.fileName(direction: .androidToMac),
            "android-to-peer-aaaaaaaaaaaaaaaa.txt"
        )
        XCTAssertEqual(
            capability.fileName(direction: .macToAndroid),
            "peer-to-android-aaaaaaaaaaaaaaaa.txt"
        )

        let payload = try capability.payload(
            direction: .androidToMac,
            sessionRef: sessionRef,
            transferID: androidToMacTransferID
        )
        XCTAssertEqual(
            String(decoding: payload, as: UTF8.self),
            """
            skybridge-formal-p2p-file-v1
            direction=android-to-peer
            runRef=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            sessionRef=\(sessionRef)
            transferId=11111111-1111-4111-8111-111111111111

            """
        )
        XCTAssertNoThrow(
            try capability.validateInboundMetadata(
                transferID: androidToMacTransferID,
                fileName: capability.fileName(direction: .androidToMac),
                fileSize: Int64(payload.count),
                senderDeviceID: "android-device-0001",
                expectedPeerDeviceID: "android-device-0001",
                sessionRef: sessionRef
            )
        )
        XCTAssertThrowsError(
            try capability.validateInboundMetadata(
                transferID: androidToMacTransferID,
                fileName: capability.fileName(direction: .androidToMac),
                fileSize: Int64(payload.count),
                senderDeviceID: " android-device-0001 ",
                expectedPeerDeviceID: "android-device-0001",
                sessionRef: sessionRef
            )
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .invalidTransferBinding)
        }
        XCTAssertThrowsError(
            try capability.payload(
                direction: .androidToMac,
                sessionRef: sessionRef,
                transferID: macToAndroidTransferID
            )
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .invalidTransferBinding)
        }
    }

    func testCapabilityRejectsNonCanonicalAuthorityInputs() throws {
        XCTAssertFalse(
            FormalMacInteropCapability.isCanonicalSHA256(String(repeating: "١", count: 32))
        )
        XCTAssertFalse(FormalMacInteropCapability.isCanonicalSHA256(String(repeating: "A", count: 64)))
        XCTAssertFalse(FormalMacInteropCapability.isCanonicalTransferID(UUID().uuidString))

        XCTAssertThrowsError(
            try makeCapability(token: "header.payload.")
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .invalidConfiguration)
        }
        XCTAssertThrowsError(
            try makeCapability(tenantID: "tenant\nother")
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .invalidConfiguration)
        }
        XCTAssertThrowsError(
            try makeCapability(macToAndroidTransferID: androidToMacTransferID)
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .invalidConfiguration)
        }
        XCTAssertTrue(CrossNetworkConnectionManager.isCanonicalFormalConnectionCode("ABCDEFGH"))
        XCTAssertFalse(CrossNetworkConnectionManager.isCanonicalFormalConnectionCode("abcdefgh"))
        XCTAssertFalse(CrossNetworkConnectionManager.isCanonicalFormalConnectionCode("ABCD-EFGH"))
        XCTAssertFalse(
            CrossNetworkConnectionManager.isCanonicalFormalConnectionCode("ABCDEFGHJKLMNPQRS")
        )
    }

    func testExclusiveWriterCreates0600NewlineTerminatedFileAndNeverReplaces() throws {
        let root = uniqueTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let runDirectory = try FormalMacInteropFileSystem.prepareRunDirectory(
            parent: root,
            runRef: runRef
        )
        let resultURL = runDirectory.appendingPathComponent("result.json")
        try FormalMacInteropFileSystem.writeExclusiveJSON(["ok": true], to: resultURL)

        let bytes = try Data(contentsOf: resultURL)
        XCTAssertEqual(bytes.last, 0x0A)
        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(
            try FormalMacInteropFileSystem.writeExclusiveJSON(["ok": false], to: resultURL)
        ) { error in
            guard case .exclusiveWriteFailed = error as? FormalMacInteropError else {
                return XCTFail("Expected an exclusive-write failure, got \(error)")
            }
        }

        try FormalMacInteropFileSystem.cleanupRunDirectory(
            runDirectory,
            parent: root,
            runRef: runRef
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testCleanupRefusesAPathOutsideTheExactRunDirectory() throws {
        let root = uniqueTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let runDirectory = try FormalMacInteropFileSystem.prepareRunDirectory(
            parent: root,
            runRef: runRef
        )
        XCTAssertThrowsError(
            try FormalMacInteropFileSystem.cleanupRunDirectory(
                root,
                parent: root,
                runRef: runRef
            )
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .cleanupFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: runDirectory.path))
    }

    func testFormalPayloadBindingRejectsWrongContentBeforeCompletionCanCommit() throws {
        let root = uniqueTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let runDirectory = try FormalMacInteropFileSystem.prepareRunDirectory(
            parent: root,
            runRef: runRef
        )
        let capability = try makeCapability(runDirectory: runDirectory)
        let sessionRef = try capability.sessionRef("12345678-1234-1234-1234-1234567890ab")
        let expected = try capability.payload(
            direction: .androidToMac,
            sessionRef: sessionRef,
            transferID: androidToMacTransferID
        )
        let temporary = try CrossNetworkInboundFileCommitter.createExclusiveTemporaryFile(
            in: runDirectory
        )
        try temporary.handle.write(contentsOf: expected)
        try CrossNetworkInboundFileCommitter.synchronizeAndClose(temporary.handle)

        XCTAssertNoThrow(
            try FormalMacInteropFileSystem.validateExpectedPayload(
                at: temporary.url,
                in: capability.runDirectory,
                payload: expected,
                actualSHA256: Data(SHA256.hash(data: expected))
            )
        )
        let committed = try CrossNetworkInboundFileCommitter.commitWithoutReplacing(
            temporaryURL: temporary.url,
            in: runDirectory,
            preferredFileName: capability.fileName(direction: .androidToMac)
        )
        XCTAssertEqual(
            committed.lastPathComponent,
            capability.fileName(direction: .androidToMac)
        )
        let wrongSameLength = Data(repeating: 0x58, count: expected.count)
        let wrongTemporary = try CrossNetworkInboundFileCommitter.createExclusiveTemporaryFile(
            in: runDirectory
        )
        try wrongTemporary.handle.write(contentsOf: wrongSameLength)
        try CrossNetworkInboundFileCommitter.synchronizeAndClose(wrongTemporary.handle)
        XCTAssertThrowsError(
            try FormalMacInteropFileSystem.validateExpectedPayload(
                at: wrongTemporary.url,
                in: capability.runDirectory,
                payload: expected,
                actualSHA256: Data(SHA256.hash(data: wrongSameLength))
            )
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .invalidTransferBinding)
        }
    }

    func testRunParentRequiresCurrentOwnerAndExact0700Mode() throws {
        let root = uniqueTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNoThrow(try FormalMacInteropFileSystem.requirePrivateDirectory(root))
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: root.path)
        XCTAssertThrowsError(try FormalMacInteropFileSystem.requirePrivateDirectory(root)) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .invalidConfiguration)
        }
        XCTAssertThrowsError(
            try FormalMacInteropFileSystem.prepareRunDirectory(parent: root, runRef: runRef)
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .invalidConfiguration)
        }
    }

    func testCompletionRegistryRevalidatesBeforeFirstAndReplayACK() throws {
        let root = uniqueTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("formal-registry-payload\n".utf8)
        let committedURL = root.appendingPathComponent("android-to-peer.txt")
        try FormalMacInteropFileSystem.writeExclusive(payload, to: committedURL)
        let owner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "formal-session-0001",
            generation: UUID(),
            keyEpoch: UUID()
        )
        let acknowledgement = try CrossNetworkFileTransferMessage.completeAcknowledgement(
            transferId: androidToMacTransferID,
            receivedBytes: Int64(payload.count),
            fileSha256: Data(SHA256.hash(data: payload))
        )
        var registry = FormalMacInboundCompletionRegistry()

        XCTAssertThrowsError(
            try registry.validateBeforeAcknowledgement(
                owner: owner,
                acknowledgement: acknowledgement
            )
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .invalidTransferBinding)
        }
        try registry.stage(
            owner: owner,
            committedURL: committedURL,
            expectedRunDirectory: root,
            expectedFileName: committedURL.lastPathComponent,
            expectedPayload: payload,
            acknowledgement: acknowledgement
        )
        let firstAttempt = try registry.validateBeforeAcknowledgement(
            owner: owner,
            acknowledgement: acknowledgement
        )
        XCTAssertEqual(firstAttempt.bytes, payload.count)
        XCTAssertFalse(registry.isEmpty, "failed ACK must leave an exact replay witness")

        let retryAttempt = try registry.validateBeforeAcknowledgement(
            owner: owner,
            acknowledgement: acknowledgement
        )
        XCTAssertEqual(retryAttempt, firstAttempt)
        let promoted = try registry.promoteAfterAcknowledgement(
            owner: owner,
            acknowledgement: acknowledgement
        )
        XCTAssertEqual(promoted, firstAttempt)
        XCTAssertFalse(registry.isEmpty, "network ACK loss must remain exactly replayable")
        XCTAssertEqual(
            try registry.validateBeforeAcknowledgement(
                owner: owner,
                acknowledgement: acknowledgement
            ),
            promoted
        )
        registry.discardAllAfterQuiescence()
        XCTAssertTrue(registry.isEmpty)
    }

    func testCompletionRegistryNeverAcknowledgesMissingOrMutatedWitness() throws {
        let root = uniqueTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("formal-registry-payload\n".utf8)
        let committedURL = root.appendingPathComponent("android-to-peer.txt")
        try FormalMacInteropFileSystem.writeExclusive(payload, to: committedURL)
        let owner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "formal-session-0001",
            generation: UUID(),
            keyEpoch: UUID()
        )
        let acknowledgement = try CrossNetworkFileTransferMessage.completeAcknowledgement(
            transferId: androidToMacTransferID,
            receivedBytes: Int64(payload.count),
            fileSha256: Data(SHA256.hash(data: payload))
        )
        var registry = FormalMacInboundCompletionRegistry()
        try registry.stage(
            owner: owner,
            committedURL: committedURL,
            expectedRunDirectory: root,
            expectedFileName: committedURL.lastPathComponent,
            expectedPayload: payload,
            acknowledgement: acknowledgement
        )
        try FileManager.default.removeItem(at: committedURL)
        try FormalMacInteropFileSystem.writeExclusive(
            Data(repeating: 0x58, count: payload.count),
            to: committedURL
        )

        XCTAssertThrowsError(
            try registry.validateBeforeAcknowledgement(
                owner: owner,
                acknowledgement: acknowledgement
            )
        )
        XCTAssertFalse(registry.isEmpty)
    }

    func testFormalNetworkSessionDisablesPersistentCredentialStores() {
        let session = FormalMacNetworkIsolation.makeEphemeralURLSession()
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
    }

    func testFormalTURNServiceUsesRunIdentityAndFailsClosedWithoutAdmissionLease() async throws {
        let session = FormalMacNetworkIsolation.makeEphemeralURLSession()
        defer { session.invalidateAndCancel() }
        let service = TURNCredentialService.formal(
            credentialEndpoint: URL(string: "https://turn.example.test/api/turn/credentials")!,
            urlSession: session,
            deviceID: "formal-mac-device-0001",
            requestTimeout: 7
        )

        let request = try await service.testingRequest(turnAdmissionToken: "formal-lease-token")
        XCTAssertEqual(request.url?.absoluteString, "https://turn.example.test/api/turn/credentials")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Id"), "formal-mac-device-0001")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-SkyBridge-Turn-Admission"),
            "formal-lease-token"
        )
        XCTAssertEqual(request.timeoutInterval, 7)

        let policy = await service.testingURLSessionPolicy()
        XCTAssertFalse(policy.hasURLCache)
        XCTAssertEqual(
            policy.requestCachePolicyRawValue,
            URLRequest.CachePolicy.reloadIgnoringLocalCacheData.rawValue
        )
        XCTAssertFalse(policy.hasHTTPCookieStorage)
        XCTAssertFalse(policy.httpShouldSetCookies)
        XCTAssertFalse(policy.hasURLCredentialStorage)

        do {
            _ = try await service.requireCredentials(
                sessionID: "FORMAL01",
                turnAdmissionLease: nil
            )
            XCTFail("Formal TURN must not silently fall back without a run admission lease")
        } catch {
            guard case TURNCredentialService.TURNCredentialError.missingTurnAdmissionToken = error else {
                return XCTFail("Expected missing admission token, got \(error)")
            }
        }

        let fallback = await service.getCredentials(
            sessionID: "FORMAL01",
            turnAdmissionLease: nil
        )
        XCTAssertTrue(fallback.username.isEmpty)
        XCTAssertTrue(fallback.password.isEmpty)
        XCTAssertTrue(fallback.uris.isEmpty, "formal service must never inherit static TURN URLs")
    }

    @MainActor
    func testFormalManagerClaimsCapabilityOnceBeforeAnAsyncContinuationCanResume() async throws {
        let manager = CrossNetworkConnectionManager(formalInteropCapability: try makeCapability())
        let firstAttempt = try manager.testingClaimFormalConnectAttempt()
        XCTAssertNotEqual(firstAttempt, UUID())

        // Model the first connect suspending after its synchronous claim. A second main-actor
        // entrant must fail immediately instead of sharing or replacing that attempt.
        await Task.yield()
        XCTAssertThrowsError(try manager.testingClaimFormalConnectAttempt()) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .capabilityAlreadyConsumed)
        }
    }

    func testFormalLifecycleNeverReturnsToAvailableAfterFailureOrRetirement() throws {
        var lifecycle = FormalMacConnectLifecycle(capabilityInstalled: true)
        let attemptID = try lifecycle.claim()
        XCTAssertEqual(lifecycle.state, .connecting(attemptID))
        XCTAssertThrowsError(try lifecycle.claim()) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .capabilityAlreadyConsumed)
        }
        try lifecycle.activate(attemptID)
        XCTAssertEqual(lifecycle.state, .active(attemptID))
        lifecycle.retire()
        XCTAssertEqual(lifecycle.state, .retired)
        XCTAssertThrowsError(try lifecycle.claim()) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .capabilityAlreadyConsumed)
        }
    }

    func testFormalPeerKEMAdmissionRequiresExactReplyCompletedPresentationAndCurrentKeyEpoch() throws {
        let owner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "FORMAL01",
            generation: UUID(),
            keyEpoch: UUID()
        )
        let trust = FormalMacPeerTrustMaterial(
            deviceID: "android-device-0001",
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
            protocolPublicKey: Data(repeating: 0x55, count: 1_952),
            kemPublicKey: Data(repeating: 0x33, count: 1_184)
        )
        let exactKeys = [
            KEMPublicKeyInfo(
                suiteWireId: FormalMacInteropCapability.suiteWireID,
                publicKey: trust.kemPublicKey
            )
        ]
        var registry = FormalMacPeerKEMAdmissionRegistry()

        XCTAssertThrowsError(
            try registry.require(sessionID: owner.sessionID, owner: owner, expectedTrust: trust)
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .peerKEMAdmissionRequired)
        }
        var replySendCount = 0
        let firstDisposition = try registry.beginReply(
            owner: owner,
            peerDeviceID: trust.deviceID,
            presentedKeys: exactKeys,
            expectedTrust: trust
        )
        guard case .sendReply(let prepared) = firstDisposition else {
            return XCTFail("first exact presentation must claim the single reply")
        }
        replySendCount += 1
        XCTAssertThrowsError(
            try registry.require(sessionID: owner.sessionID, owner: owner, expectedTrust: trust),
            "preparing before the reply completes must not admit file or evidence operations"
        )
        XCTAssertTrue(
            FormalMacSessionBindingWaitPolicy.isRetryable(.peerKEMAdmissionRequired),
            "the host must keep the same bounded deadline while the exact pairing reply is pending"
        )
        XCTAssertTrue(FormalMacSessionBindingWaitPolicy.isRetryable(.selectedICEUnavailable))
        XCTAssertFalse(FormalMacSessionBindingWaitPolicy.isRetryable(.missingExactPeerTrust))
        XCTAssertFalse(FormalMacSessionBindingWaitPolicy.isRetryable(.staleSession))
        XCTAssertThrowsError(
            try registry.beginReply(
                owner: owner,
                peerDeviceID: trust.deviceID,
                presentedKeys: [
                    KEMPublicKeyInfo(
                        suiteWireId: FormalMacInteropCapability.suiteWireID,
                        publicKey: Data(repeating: 0x44, count: 1_184)
                    )
                ],
                expectedTrust: trust
            )
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .missingExactPeerTrust)
        }

        try registry.installAfterReply(prepared)
        XCTAssertNoThrow(
            try registry.require(sessionID: owner.sessionID, owner: owner, expectedTrust: trust)
        )
        let duplicateDisposition = try registry.beginReply(
            owner: owner,
            peerDeviceID: trust.deviceID,
            presentedKeys: exactKeys,
            expectedTrust: trust
        )
        if case .sendReply = duplicateDisposition {
            replySendCount += 1
        }
        XCTAssertEqual(duplicateDisposition, .noReplyRequired)
        XCTAssertEqual(replySendCount, 1, "an exact duplicate must not echo another pairing reply")

        let nextOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: owner.sessionID,
            generation: owner.sessionGeneration,
            keyEpoch: UUID()
        )
        XCTAssertThrowsError(
            try registry.require(sessionID: owner.sessionID, owner: nextOwner, expectedTrust: trust)
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .peerKEMAdmissionRequired)
        }
        XCTAssertThrowsError(
            try registry.beginReply(
                owner: nextOwner,
                peerDeviceID: trust.deviceID,
                presentedKeys: exactKeys,
                expectedTrust: trust
            )
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .staleSession)
        }
    }

    func testStaleSignalingHandleCannotDeliverLeaveOrServerError() async throws {
        let client = WebSocketSignalingClient(
            url: URL(string: "wss://signal.example.test/ws")!,
            sessionId: "FORMAL01",
            generation: 2
        )
        let current = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "FORMAL01",
            backend: .urlSession,
            generation: 2
        )
        let stale = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "FORMAL01",
            backend: .native,
            generation: 1
        )
        let recorder = FormalSignalingDeliveryRecorder()
        await client.setOnEnvelope { _, envelope in recorder.recordEnvelope(envelope) }
        await client.setOnServerFrame { _, frame in recorder.recordServerFrame(frame) }
        await client.testOnlyInstallCurrentHandle(current)

        let leave = WebRTCSignalingEnvelope(
            sessionId: "FORMAL01",
            from: "persistent-peer-id",
            type: .leave
        )
        let offer = WebRTCSignalingEnvelope(
            sessionId: "FORMAL01",
            from: "persistent-peer-id",
            type: .offer,
            payload: .init(sdp: "attacker-controlled-sdp")
        )
        let offerText = String(decoding: try JSONEncoder().encode(offer), as: UTF8.self)
        let leaveText = String(decoding: try JSONEncoder().encode(leave), as: UTF8.self)
        let errorText = #"{"type":"error","error":"attacker-controlled","sessionId":"FORMAL01"}"#

        await client.testOnlyHandleText(handleId: stale, text: offerText)
        await client.testOnlyHandleText(handleId: stale, text: leaveText)
        await client.testOnlyHandleText(handleId: stale, text: errorText)
        XCTAssertEqual(recorder.envelopeTypes, [])
        XCTAssertEqual(recorder.serverFrameTypes, [])

        await client.testOnlyHandleText(handleId: current, text: offerText)
        await client.testOnlyHandleText(handleId: current, text: leaveText)
        await client.testOnlyHandleText(handleId: current, text: errorText)
        XCTAssertEqual(recorder.envelopeTypes, [.offer, .leave])
        XCTAssertEqual(recorder.serverFrameTypes, ["error"])
    }

    func testCloseClearsCallbacksAndClientCanDeallocateWithoutResurrection() async throws {
        weak var weakClient: WebSocketSignalingClient?
        let recorder = FormalSignalingDeliveryRecorder()
        do {
            let client = WebSocketSignalingClient(
                url: URL(string: "wss://signal.example.test/ws")!,
                sessionId: "FORMAL01",
                generation: 1
            )
            weakClient = client
            let handle = WebSocketSignalingClient.SignalingHandleID(
                sessionId: "FORMAL01",
                backend: .urlSession,
                generation: 1
            )
            await client.setOnEnvelope { [weak client] _, envelope in
                _ = client
                recorder.recordEnvelope(envelope)
            }
            await client.testOnlyInstallCurrentHandle(handle)
            await client.close()
            await client.testOnlyHandleText(
                handleId: handle,
                text: String(
                    decoding: try JSONEncoder().encode(
                        WebRTCSignalingEnvelope(
                            sessionId: "FORMAL01",
                            from: "persistent-peer-id",
                            type: .leave
                        )
                    ),
                    as: UTF8.self
                )
            )
        }
        XCTAssertEqual(recorder.envelopeTypes, [])
        await Task.yield()
        XCTAssertNil(weakClient)
    }

    func testFormalSourceContractsKeepAuthorityOutOfDiagnosticsAndCentralizeCompletionACK() throws {
        let root = repositoryRoot()
        let manager = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
            ),
            encoding: .utf8
        )
        let signaling = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeAppleTransport/RemoteConnection/WebRTC/WebSocketSignalingClient.swift"
            ),
            encoding: .utf8
        )
        let webRTC = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift"
            ),
            encoding: .utf8
        )
        let turn = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/Config/TURNCredentialService.swift"
            ),
            encoding: .utf8
        )
        let handshakeContext = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/P2P/HandshakeContext.swift"
            ),
            encoding: .utf8
        )
        let handshakeDriver = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/P2P/HandshakeDriver.swift"
            ),
            encoding: .utf8
        )

        for forbidden in [
            #"session=\(sessionID)"#,
            #"session=\(authorizedEnvelope.sessionId)"#,
            #"session=\(env.sessionId)"#,
            #"peer=\(peerDeviceId, privacy: .public)"#,
            #"peer=\(selectedPeerId, privacy: .public)"#,
            #"deviceId=\(payload.deviceId)"#,
            #"deviceId=\(localId)"#,
            #"error=\(error.localizedDescription)"#,
            #"err=\(error.localizedDescription, privacy: .public)"#,
            #"unknown preview=\(preview)"#
        ] {
            XCTAssertFalse(manager.contains(forbidden), "raw diagnostic interpolation remains: \(forbidden)")
        }
        XCTAssertFalse(manager.contains("TURNCredentialService.shared.clearCache"))
        XCTAssertFalse(manager.contains("TURN+STUN: user="))
        XCTAssertFalse(signaling.contains("text.prefix(200)"))
        XCTAssertFalse(signaling.contains(#"server error: \(reason, privacy: .public)"#))
        XCTAssertFalse(signaling.contains(#"err=\(error.localizedDescription, privacy: .public)"#))
        XCTAssertFalse(webRTC.contains(#"failed: \(error.localizedDescription, privacy: .public)"#))
        XCTAssertFalse(webRTC.contains(#"label=\(dataChannel.label, privacy: .public)"#))
        XCTAssertFalse(manager.contains("preimageSha256"))
        XCTAssertFalse(handshakeDriver.contains("transcriptHashPrefix"))
        XCTAssertFalse(manager.contains(#"lastRekeyEvent = "received peer=\(peerDeviceId)""#))
        XCTAssertFalse(manager.contains(#"lastRekeyEvent = "failed reason=\(error.localizedDescription)""#))
        XCTAssertTrue(manager.contains("[weak self, weak newCandidate]"))
        XCTAssertTrue(manager.contains("let detachedSignalingClient = signalingClient"))
        XCTAssertTrue(signaling.contains("private var connectionEpoch: UInt64 = 0"))
        XCTAssertTrue(signaling.contains("connectionEpoch &+= 1"))
        XCTAssertTrue(manager.contains("formalPeerKEMAdmissions.beginReply("))
        XCTAssertTrue(manager.contains("formalPeerKEMAdmissions.cancelReply("))
        XCTAssertTrue(turn.contains("allowStaticTURNFallbackProvider: { false }"))
        XCTAssertTrue(manager.contains("deviceID: formalInteropCapability.localIdentity.deviceID"))
        for forbidden in [
            "staticSecretSha256",
            "sessionSecretSha256",
            "payloadKeySha256",
            "preimageSha256",
            "smokePQCLoggingEnabled"
        ] {
            XCTAssertFalse(
                handshakeContext.contains(forbidden),
                "secret-derived handshake diagnostic remains: \(forbidden)"
            )
        }

        XCTAssertEqual(manager.components(separatedBy: "sendValidatedCompletionAcknowledgement(").count - 1, 4)
        XCTAssertEqual(manager.components(separatedBy: "sendCompletionAcknowledgementBestEffort(").count - 1, 2)
        let helperStart = try XCTUnwrap(manager.range(of: "func sendValidatedCompletionAcknowledgement("))
        let helperEnd = try XCTUnwrap(
            manager.range(of: "func sendFileTransferResponse(", range: helperStart.upperBound..<manager.endIndex)
        )
        let helper = String(manager[helperStart.lowerBound..<helperEnd.lowerBound])
        let validate = try XCTUnwrap(helper.range(of: "validateBeforeAcknowledgement"))
        let send = try XCTUnwrap(helper.range(of: "sendCompletionAcknowledgementBestEffort"))
        let promote = try XCTUnwrap(helper.range(of: "promoteAfterAcknowledgement"))
        XCTAssertLessThan(validate.lowerBound, send.lowerBound)
        XCTAssertLessThan(send.lowerBound, promote.lowerBound)

        let connectStart = try XCTUnwrap(manager.range(of: "public func connectWithCode("))
        let connectEnd = try XCTUnwrap(
            manager.range(of: "// MARK: - 私有方法 - P2P", range: connectStart.upperBound..<manager.endIndex)
        )
        let connect = String(manager[connectStart.lowerBound..<connectEnd.lowerBound])
        let claim = try XCTUnwrap(connect.range(of: "claimFormalConnectAttempt()"))
        let firstAwait = try XCTUnwrap(connect.range(of: "await currentPathLocalBinding()"))
        XCTAssertLessThan(claim.lowerBound, firstAwait.lowerBound)
        XCTAssertTrue(connect.contains("formalAttemptID: formalAttemptID"))
    }

    func testFormalHandshakeIdentityRejectsLegacyCompatibilityEncoding() throws {
        let canonical = IdentityPublicKeys(
            protocolPublicKey: Data(repeating: 0x42, count: 1_952),
            protocolAlgorithm: .mlDSA65,
            secureEnclavePublicKey: nil
        ).encoded
        let decoded = try FormalMacHandshakeAdmission.requireCanonicalIdentityPublicKeys(canonical)
        XCTAssertEqual(decoded.protocolAlgorithm, .mlDSA65)
        XCTAssertEqual(decoded.protocolPublicKey.count, 1_952)

        let legacyP256 = Data([0x04] + [UInt8](repeating: 0x11, count: 64))
        XCTAssertNoThrow(try IdentityPublicKeys.decodeWithLegacyFallback(from: legacyP256))
        XCTAssertThrowsError(
            try FormalMacHandshakeAdmission.requireCanonicalIdentityPublicKeys(legacyP256)
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .missingExactPeerTrust)
        }
        XCTAssertThrowsError(
            try FormalMacHandshakeAdmission.requireCanonicalIdentityPublicKeys(
                canonical + Data([0x00])
            )
        ) { error in
            XCTAssertEqual(error as? FormalMacInteropError, .missingExactPeerTrust)
        }
    }

    func testExistingTrustRequiresOneActiveExactMLDSAAndMLKEM768Record() throws {
        let record = makeTrustRecord()
        let resolved = try TrustSyncService.requireExactFormalPeerTrustRecord(
            records: [record],
            deviceID: record.deviceId,
            protocolPublicKeyFingerprint: record.protocolPublicKeyFingerprint!
        )
        XCTAssertEqual(resolved, record)
    }

    func testExistingTrustRejectsDuplicateRevokedAndCorruptRecords() throws {
        let exact = makeTrustRecord()
        let fingerprint = try XCTUnwrap(exact.protocolPublicKeyFingerprint)

        assertFormalTrustError(.duplicatePeerTrust) {
            _ = try TrustSyncService.requireExactFormalPeerTrustRecord(
                records: [exact, exact],
                deviceID: exact.deviceId,
                protocolPublicKeyFingerprint: fingerprint
            )
        }
        let historicalAlias = makeTrustRecord(
            deviceID: "android-device-0002",
            protocolPublicKey: exact.protocolPublicKey!,
            protocolPublicKeyFingerprint: fingerprint,
            knownDeviceIDs: [exact.deviceId, "android-device-0002"]
        )
        assertFormalTrustError(.missingExactPeerTrust) {
            _ = try TrustSyncService.requireExactFormalPeerTrustRecord(
                records: [historicalAlias],
                deviceID: exact.deviceId,
                protocolPublicKeyFingerprint: fingerprint
            )
        }
        assertFormalTrustError(.revokedPeerTrust) {
            _ = try TrustSyncService.requireExactFormalPeerTrustRecord(
                records: [exact.revoked(signature: Data(repeating: 0x01, count: 64))],
                deviceID: exact.deviceId,
                protocolPublicKeyFingerprint: fingerprint
            )
        }
        assertFormalTrustError(.corruptPeerTrust) {
            _ = try TrustSyncService.requireExactFormalPeerTrustRecord(
                records: [makeTrustRecord(kemPublicKey: Data(repeating: 0x33, count: 1_183))],
                deviceID: exact.deviceId,
                protocolPublicKeyFingerprint: fingerprint
            )
        }
        let conflictingFingerprintKey = Data(repeating: 0x56, count: 1_952)
        let conflictingFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA65,
            publicKeyBytes: conflictingFingerprintKey
        )
        assertFormalTrustError(.duplicatePeerTrust) {
            _ = try TrustSyncService.requireExactFormalPeerTrustRecord(
                records: [
                    exact,
                    makeTrustRecord(
                        protocolPublicKey: conflictingFingerprintKey,
                        protocolPublicKeyFingerprint: conflictingFingerprint
                    )
                ],
                deviceID: exact.deviceId,
                protocolPublicKeyFingerprint: fingerprint
            )
        }
        assertFormalTrustError(.duplicatePeerTrust) {
            _ = try TrustSyncService.requireExactFormalPeerTrustRecord(
                records: [
                    exact,
                    makeTrustRecord(
                        deviceID: "android-device-0002",
                        protocolPublicKey: exact.protocolPublicKey!,
                        protocolPublicKeyFingerprint: fingerprint
                    )
                ],
                deviceID: exact.deviceId,
                protocolPublicKeyFingerprint: fingerprint
            )
        }
        assertFormalTrustError(.corruptPeerTrust) {
            _ = try TrustSyncService.requireExactFormalPeerTrustRecord(
                records: [
                    makeTrustRecord(
                        kemPublicKeys: [
                            KEMPublicKeyInfo(
                                suiteWireId: FormalMacInteropCapability.suiteWireID,
                                publicKey: Data(repeating: 0x33, count: 1_184)
                            ),
                            KEMPublicKeyInfo(
                                suiteWireId: FormalMacInteropCapability.suiteWireID,
                                publicKey: Data(repeating: 0x44, count: 1_184)
                            )
                        ]
                    )
                ],
                deviceID: exact.deviceId,
                protocolPublicKeyFingerprint: fingerprint
            )
        }
    }

    func testStaticKEMStoreAcceptsOnlyExactSuiteAndLiboqsTier() async throws {
        let store = StaticHandshakeKEMIdentityStore(
            suiteWireID: FormalMacInteropCapability.suiteWireID,
            publicKey: Data(repeating: 0x33, count: 1_184),
            privateKey: SecureBytes(data: Data(repeating: 0x44, count: 2_400))
        )
        let provider = OQSPQCCryptoProvider()
        let material = try await store.getOrCreateKEMIdentityKey(
            for: .mlkem768MLDSA65,
            provider: provider
        )
        XCTAssertEqual(material.publicKey.count, 1_184)
        XCTAssertEqual(material.privateKey.data.count, 2_400)

        do {
            _ = try await store.getOrCreateKEMIdentityKey(
                for: .mlkem768MLDSA65FS,
                provider: provider
            )
            XCTFail("Forward-secure suite must not alias the formal 0x0101 authority")
        } catch {
            XCTAssertEqual(error as? FormalMacInteropError, .inconsistentExistingIdentity)
        }
    }

    private func makeCapability(
        token: String? = nil,
        tenantID: String = "tenant-formal-001",
        macToAndroidTransferID: String? = nil,
        runDirectory: URL = URL(fileURLWithPath: "/tmp/skybridge-formal-test", isDirectory: true)
    ) throws -> FormalMacInteropCapability {
        try FormalMacInteropCapability(
            runRef: runRef,
            androidToMacTransferID: androidToMacTransferID,
            macToAndroidTransferID: macToAndroidTransferID ?? self.macToAndroidTransferID,
            bearerToken: token ?? self.token,
            tenantID: tenantID,
            runDirectory: runDirectory,
            localIdentity: FormalMacLocalIdentityMaterial(
                deviceID: "mac-device-0000001",
                protocolPublicKey: Data(repeating: 0x11, count: 1_952),
                protocolSigningKeyHandle: .softwareKey(Data(repeating: 0x22, count: 64)),
                kemPublicKey: Data(repeating: 0x33, count: 1_184),
                kemPrivateKey: SecureBytes(data: Data(repeating: 0x44, count: 2_400))
            )
        )
    }

    private func makeTrustRecord(
        deviceID: String = "android-device-0001",
        protocolPublicKey: Data = Data(repeating: 0x55, count: 1_952),
        protocolPublicKeyFingerprint: String? = nil,
        knownDeviceIDs: [String]? = nil,
        kemPublicKey: Data = Data(repeating: 0x33, count: 1_184),
        kemPublicKeys: [KEMPublicKeyInfo]? = nil
    ) -> TrustRecord {
        let fingerprint = protocolPublicKeyFingerprint
            ?? ProtocolIdentityBinding.computeFingerprint(
                algorithm: .mlDSA65,
                publicKeyBytes: protocolPublicKey
            )
        return TrustRecord(
            deviceId: deviceID,
            pubKeyFP: fingerprint,
            publicKey: Data(repeating: 0x66, count: 65),
            protocolPublicKey: protocolPublicKey,
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint,
            signatureAlgorithm: .mlDSA65,
            kemPublicKeys: kemPublicKeys ?? [
                KEMPublicKeyInfo(
                    suiteWireId: FormalMacInteropCapability.suiteWireID,
                    publicKey: kemPublicKey
                )
            ],
            signature: Data(repeating: 0x77, count: 64),
            currentDeviceId: deviceID,
            knownDeviceIds: knownDeviceIDs ?? [deviceID],
            lifecycleState: .active
        )
    }

    private func assertFormalTrustError(
        _ expected: FormalMacInteropError,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? FormalMacInteropError, expected)
        }
    }

    private func uniqueTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "skybridge-formal-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

@MainActor
private final class FormalSignalingOrderRecorder {
    var values: [String] = []
}

private final class FormalSignalingDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEnvelopeTypes: [WebRTCSignalingEnvelope.MessageType] = []
    private var storedServerFrameTypes: [String] = []

    var envelopeTypes: [WebRTCSignalingEnvelope.MessageType] {
        lock.withLock { storedEnvelopeTypes }
    }

    var serverFrameTypes: [String] {
        lock.withLock { storedServerFrameTypes }
    }

    func recordEnvelope(_ envelope: WebRTCSignalingEnvelope) {
        lock.withLock { storedEnvelopeTypes.append(envelope.type) }
    }

    func recordServerFrame(_ frame: WebSocketSignalingClient.SignalingServerFrame) {
        lock.withLock { storedServerFrameTypes.append(frame.type) }
    }
}
