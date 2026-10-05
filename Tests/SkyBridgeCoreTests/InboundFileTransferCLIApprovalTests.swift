import CryptoKit
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCore

@MainActor
final class InboundFileTransferCLIApprovalTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let registry = RemoteFileApprovalRegistry()
        lazy var service = InboundFileTransferApprovalService(remoteRegistry: registry)
        let peer: HandshakeManagementIdentity
        let request: InboundFileTransferApprovalService.Request
        let binding: RemoteFileApprovalBinding
        var sessionCurrent = true
        var suspendSessionCheck = false
        var sessionCheckStarted = false
        var sessionCheckContinuation: CheckedContinuation<Void, Never>?

        init() throws {
            let key = Data(repeating: 7, count: 1952)
            peer = HandshakeManagementIdentity(
                deviceID: "00000000-0000-0000-0000-000000000002", algorithm: "ML-DSA-65",
                publicKey: key,
                fingerprint: ProtocolIdentityBinding.computeFingerprint(algorithm: .mlDSA65, publicKeyBytes: key)
            )
            request = InboundFileTransferApprovalService.Request(
                transferId: UUID().uuidString, fileName: "payload.bin", fileSize: 4,
                chunkSize: 4, totalChunks: 1, senderDeviceId: peer.deviceID,
                senderDeviceName: "Paired Mac", endpointDescription: "paired.local",
                destinationDirectoryPath: "/tmp/SkyBridge", proposedSavePath: "/tmp/SkyBridge/payload.bin"
            )
            binding = try RemoteFileApprovalBinding(
                transferID: request.transferId, senderDeviceID: peer.deviceID,
                senderFingerprint: peer.fingerprint,
                sessionReference: XCTUnwrap(P2PEvidenceReference.sessionIncarnation(
                    sessionID: "mac-cli-approval", transcriptHash: Data(repeating: 8, count: 32)
                )), metadataDigest: String(repeating: "a", count: 64),
                fileName: request.fileName, fileSize: request.fileSize, fileSHA256: String(repeating: "b", count: 64)
            )
        }

        func context(_ binding: RemoteFileApprovalBinding? = nil) -> RemoteFileApprovalContext {
            RemoteFileApprovalContext(binding: binding ?? self.binding) { [self] in
                if suspendSessionCheck {
                    suspendSessionCheck = false
                    sessionCheckStarted = true
                    await withCheckedContinuation { sessionCheckContinuation = $0 }
                }
                guard sessionCurrent else { throw RemoteFileApprovalError.bindingChanged }
            }
        }

        func begin() async throws -> Task<InboundFileTransferApprovalService.Decision, Never> {
            let task = Task { @MainActor in await service.decide(for: request, remoteApproval: context()) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while service.pendingRequest == nil && ContinuousClock.now < deadline { await Task.yield() }
            guard service.pendingRequest != nil else {
                task.cancel()
                throw RemoteFileApprovalError.unavailable
            }
            return task
        }
    }

    func testTerminalDecisionResolvesTheNativeReceiveExactlyOnce() async throws {
        let f = try Fixture(), task = try await f.begin()
        defer { task.cancel(); f.service.userDismissedCurrentPrompt() }
        let prompt = try XCTUnwrap(f.registry.pending(for: f.peer).first)
        XCTAssertEqual(prompt.binding, f.binding)
        try await f.registry.decide(.init(prompt: prompt, allow: true), requester: f.peer)
        let result = await task.value
        XCTAssertEqual(result, .allowOnce)
        XCTAssertNil(f.service.pendingRequest)
        XCTAssertTrue(try f.registry.pending(for: f.peer).isEmpty)
        do {
            try await f.registry.decide(.init(prompt: prompt, allow: true), requester: f.peer)
            XCTFail("A completed receive decision must not replay")
        } catch let error as RemoteFileApprovalError { XCTAssertEqual(error, .stale) }
    }

    func testNativeRejectionRemovesTheTerminalDecision() async throws {
        let f = try Fixture(), task = try await f.begin()
        defer { task.cancel(); f.service.userDismissedCurrentPrompt() }
        f.service.resolve(f.request, decision: .reject)
        let result = await task.value
        XCTAssertEqual(result, .reject)
        XCTAssertTrue(try f.registry.pending(for: f.peer).isEmpty)
    }

    func testChangedSessionRejectsTheReceiveAndRetiresBothPrompts() async throws {
        let f = try Fixture(), task = try await f.begin()
        defer { task.cancel(); f.service.userDismissedCurrentPrompt() }
        let prompt = try XCTUnwrap(f.registry.pending(for: f.peer).first)
        f.sessionCurrent = false
        do {
            try await f.registry.decide(.init(prompt: prompt, allow: true), requester: f.peer)
            XCTFail("A decision from a replaced session must not authorize a write")
        } catch let error as RemoteFileApprovalError { XCTAssertEqual(error, .bindingChanged) }
        let result = await task.value
        XCTAssertEqual(result, .reject)
        XCTAssertNil(f.service.pendingRequest)
        XCTAssertTrue(try f.registry.pending(for: f.peer).isEmpty)
    }

    func testCancellationRemovesTheTerminalDecision() async throws {
        let f = try Fixture(), task = try await f.begin()
        defer { task.cancel(); f.service.userDismissedCurrentPrompt() }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .reject)
        XCTAssertNil(f.service.pendingRequest)
        XCTAssertTrue(try f.registry.pending(for: f.peer).isEmpty)
    }

    func testDuplicateFileCannotJoinAnApprovalForDifferentAuthenticatedMetadata() async throws {
        let f = try Fixture(), task = try await f.begin()
        defer { task.cancel(); f.service.userDismissedCurrentPrompt() }
        let changed = try RemoteFileApprovalBinding(
            transferID: f.binding.transferID, senderDeviceID: f.peer.deviceID,
            senderFingerprint: f.peer.fingerprint, sessionReference: f.binding.sessionReference,
            metadataDigest: String(repeating: "c", count: 64), fileName: f.request.fileName,
            fileSize: f.request.fileSize, fileSHA256: f.binding.fileSHA256
        )
        let duplicate = await f.service.decide(for: f.request, remoteApproval: f.context(changed))
        XCTAssertEqual(duplicate, .reject)
        XCTAssertEqual(try f.registry.pending(for: f.peer).first?.binding, f.binding)
        f.service.resolve(f.request, decision: .reject)
        let result = await task.value
        XCTAssertEqual(result, .reject)
    }

    func testNativeCancellationDuringAwaitedSessionCheckCannotBecomeTerminalSuccess() async throws {
        let f = try Fixture(), receive = try await f.begin()
        defer {
            receive.cancel()
            f.service.userDismissedCurrentPrompt()
            f.sessionCheckContinuation?.resume()
            f.sessionCheckContinuation = nil
        }
        let prompt = try XCTUnwrap(f.registry.pending(for: f.peer).first)
        f.suspendSessionCheck = true
        let decision = Task { @MainActor in
            try await f.registry.decide(.init(prompt: prompt, allow: true), requester: f.peer)
        }
        defer { decision.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !f.sessionCheckStarted && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(f.sessionCheckStarted)
        f.service.resolve(f.request, decision: .reject)
        f.sessionCheckContinuation?.resume()
        f.sessionCheckContinuation = nil
        do {
            try await decision.value
            XCTFail("An expired native owner cannot be approved after an awaited session check")
        } catch let error as RemoteFileApprovalError { XCTAssertEqual(error, .stale) }
        let result = await receive.value
        XCTAssertEqual(result, .reject)
        XCTAssertTrue(try f.registry.pending(for: f.peer).isEmpty)
    }
}
