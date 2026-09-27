import CryptoKit
import Foundation
import XCTest
import SkyBridgeProtocolCore

@MainActor
final class RemoteFileApprovalRegistryTests: XCTestCase {
    private func identity(_ byte: UInt8 = 3) -> HandshakeManagementIdentity {
        let key = Data(repeating: byte, count: 1952)
        return .init(deviceID: "00000000-0000-0000-0000-000000000001", algorithm: "ML-DSA-65", publicKey: key,
            fingerprint: ProtocolIdentityBinding.computeFingerprint(algorithm: .mlDSA65, publicKeyBytes: key))
    }
    private func binding(owner: HandshakeManagementIdentity) throws -> RemoteFileApprovalBinding {
        try .init(transferID: UUID().uuidString, senderDeviceID: "id:" + owner.deviceID,
            senderFingerprint: owner.fingerprint,
            sessionReference: XCTUnwrap(P2PEvidenceReference.sessionIncarnation(sessionID: "test-session", transcriptHash: Data(repeating: 4, count: 32))),
            metadataDigest: String(repeating: "a", count: 64), fileName: "proof.txt", fileSize: 87,
            fileSHA256: String(repeating: "b", count: 64))
    }
    private final class Decisions { var values: [Bool] = [] }

    func testDecisionConsumesExactPendingRequestAndCannotReplay() async throws {
        let registry = RemoteFileApprovalRegistry(), owner = identity(), decisions = Decisions()
        let prompt = try registry.register(binding: binding(owner: owner), nativeRequestID: UUID(),
            expiresAt: Date().addingTimeInterval(60), revalidate: {}, resolve: { decisions.values.append($0); return true })
        XCTAssertEqual(try registry.pending(for: owner), [prompt])
        try await registry.decide(.init(prompt: prompt, allow: true), requester: owner)
        XCTAssertEqual(decisions.values, [true]); XCTAssertTrue(try registry.pending(for: owner).isEmpty)
        do { try await registry.decide(.init(prompt: prompt, allow: true), requester: owner); XCTFail("replay accepted") }
        catch { XCTAssertEqual(error as? RemoteFileApprovalError, .stale) }
        XCTAssertEqual(decisions.values, [true])
    }
    func testDifferentIdentityCannotSeeOrDecideEvenWithSameDeviceUUID() async throws {
        let registry = RemoteFileApprovalRegistry(), owner = identity(), other = identity(5), decisions = Decisions()
        let prompt = try registry.register(binding: binding(owner: owner), nativeRequestID: UUID(),
            expiresAt: Date().addingTimeInterval(60), revalidate: {}, resolve: { decisions.values.append($0); return true })
        XCTAssertTrue(try registry.pending(for: other).isEmpty)
        do { try await registry.decide(.init(prompt: prompt, allow: true), requester: other); XCTFail("wrong fingerprint accepted") }
        catch { XCTAssertEqual(error as? RemoteFileApprovalError, .unauthorized) }
        XCTAssertTrue(decisions.values.isEmpty); XCTAssertEqual(try registry.pending(for: owner), [prompt])
    }
    func testTamperedMetadataOrNonceCannotResolveNativePrompt() async throws {
        let registry = RemoteFileApprovalRegistry(), owner = identity(), decisions = Decisions()
        let prompt = try registry.register(binding: binding(owner: owner), nativeRequestID: UUID(),
            expiresAt: Date().addingTimeInterval(60), revalidate: {}, resolve: { decisions.values.append($0); return true })
        let encoder = JSONEncoder()
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(prompt)) as? [String: Any])
        var fields = try XCTUnwrap(wire["binding"] as? [String: Any]); fields["fileName"] = "different.txt"; wire["binding"] = fields
        let altered = try JSONDecoder().decode(RemoteFileApprovalPrompt.self, from: JSONSerialization.data(withJSONObject: wire))
        do { try await registry.decide(.init(prompt: altered, allow: true), requester: owner); XCTFail("different metadata accepted") }
        catch { XCTAssertEqual(error as? RemoteFileApprovalError, .bindingChanged) }
        XCTAssertTrue(decisions.values.isEmpty)
    }
    func testRekeyOrRevocationBeforeDecisionFailsClosed() async throws {
        let registry = RemoteFileApprovalRegistry(), owner = identity(), decisions = Decisions()
        let prompt = try registry.register(binding: binding(owner: owner), nativeRequestID: UUID(),
            expiresAt: Date().addingTimeInterval(60), revalidate: { throw RemoteFileApprovalError.bindingChanged },
            resolve: { decisions.values.append($0); return true })
        do { try await registry.decide(.init(prompt: prompt, allow: true), requester: owner); XCTFail("stale session approved") }
        catch { XCTAssertEqual(error as? RemoteFileApprovalError, .bindingChanged) }
        XCTAssertEqual(decisions.values, [false])
    }
    func testNativeDismissalAndProcessRestartInvalidateTicket() async throws {
        let registry = RemoteFileApprovalRegistry(), owner = identity(), decisions = Decisions(), id = UUID()
        let prompt = try registry.register(binding: binding(owner: owner), nativeRequestID: id,
            expiresAt: Date().addingTimeInterval(60), revalidate: {}, resolve: { decisions.values.append($0); return true })
        registry.remove(nativeRequestID: id)
        for service in [registry, RemoteFileApprovalRegistry()] {
            do { try await service.decide(.init(prompt: prompt, allow: true), requester: owner); XCTFail("unowned native prompt approved") }
            catch { XCTAssertEqual(error as? RemoteFileApprovalError, .stale) }
        }
        XCTAssertTrue(decisions.values.isEmpty)
    }
    func testExpiryRejectsPendingNativeContinuation() throws {
        let registry = RemoteFileApprovalRegistry(), owner = identity(), decisions = Decisions(), now = Date()
        _ = try registry.register(binding: binding(owner: owner), nativeRequestID: UUID(),
            expiresAt: now.addingTimeInterval(1), now: now, revalidate: {}, resolve: { decisions.values.append($0); return true })
        XCTAssertTrue(try registry.pending(for: owner, now: now.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(decisions.values, [false])
    }
    func testNativeOwnerAlreadyFinishedCannotClaimApprovalSuccess() async throws {
        let registry = RemoteFileApprovalRegistry(), owner = identity()
        let prompt = try registry.register(binding: binding(owner: owner), nativeRequestID: UUID(),
            expiresAt: Date().addingTimeInterval(60), revalidate: {}, resolve: { _ in false })
        do { try await registry.decide(.init(prompt: prompt, allow: true), requester: owner); XCTFail("missing native owner reported success") }
        catch { XCTAssertEqual(error as? RemoteFileApprovalError, .stale) }
    }
}
