import Foundation
import CryptoKit
import XCTest
import SkyBridgeProtocolCore
#if os(iOS)
@testable import SkyBridgeCompass_iOS
#else
@testable import SkyBridgeCore
#endif

@available(macOS 14.0, iOS 17.0, *)
final class SignedKEMNegotiationCacheTests: XCTestCase {
    private struct Fixture: Decodable { let vectors: [Vector] }
    private struct Vector: Decodable { let name: String; let request: AppMessage.KEMRefreshRequestPayload; let response: AppMessage.SignedKEMRefreshPayload }
    private func changed<T: Codable>(_ value: T, fields: [String: Any]) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for (key, value) in fields { object[key] = value }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func fresh(_ name: String) throws -> Vector {
        #if HAS_APPLE_PQC_SDK
        guard #available(macOS 26.0, iOS 26.0, *) else { throw XCTSkip("ML-DSA-65 runtime unavailable") }
        #if os(iOS)
        let bundle = Bundle(for: Self.self)
        #else
        let bundle = Bundle.module
        #endif
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: XCTUnwrap(bundle.url(forResource: "skr3-golden", withExtension: "json"))))
        let vector = try XCTUnwrap(fixture.vectors.first { $0.name == name })
        // Process-local key, never a shared user Keychain identity.
        let key = try MLDSA65.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(algorithm: .mlDSA65, publicKeyBytes: publicKey)
        let now = Date()
        let requester = "id:11111111-1111-4111-8111-111111111111"
        let responder = "id:22222222-2222-4222-8222-222222222222"
        let request = try changed(vector.request, fields: ["requesterDeviceId": requester, "targetDeviceId": responder,
            "requesterProtocolIdentityFingerprint": fingerprint, "targetProtocolIdentityFingerprint": fingerprint,
            "sentAt": now.timeIntervalSinceReferenceDate])
        let unsigned = try changed(vector.response, fields: ["deviceId": responder, "aliases": [responder],
            "protocolIdentityPublicKey": publicKey.base64EncodedString(), "protocolIdentityFingerprint": fingerprint,
            "requestHashHex": request.canonicalRequestHashHex, "sentAt": now.timeIntervalSinceReferenceDate,
            "expiresAt": now.addingTimeInterval(300).timeIntervalSinceReferenceDate])
        let response = try changed(unsigned, fields: ["signature": key.signature(for: unsigned.signaturePreimage).base64EncodedString()])
        return Vector(name: name, request: request, response: response)
        #else
        throw XCTSkip("Apple PQC SDK is not compiled into this test target")
        #endif
    }
    private func defaults() throws -> (String, UserDefaults) {
        let name = "signed-negotiation-\(UUID().uuidString)"
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }
    #if os(iOS)
    private let cacheKey = "negotiation-test-cache"
    private func store(_ name: String) throws -> KEMTrustStore {
        KEMTrustStore(storageKey: cacheKey, userDefaults: try XCTUnwrap(UserDefaults(suiteName: name)), authorityJournalExists: { false }, pairingAcceptanceJournalExists: { false })
    }
    private func evidence(_ store: KEMTrustStore, _ id: String) async -> KEMTrustStore.SignedRefreshEvidence? {
        await store.signedRefreshEvidence(forAny: [id])
    }
    #else
    private let cacheKey = "com.skybridge.p2p.bootstrap_kem_store.v1"
    private func store(_ name: String) throws -> PeerKEMBootstrapStore { PeerKEMBootstrapStore(defaults: try XCTUnwrap(UserDefaults(suiteName: name))) }
    private func evidence(_ store: PeerKEMBootstrapStore, _ id: String) async -> PeerKEMBootstrapStore.SignedRefreshEvidence? {
        await store.signedRefreshEvidence(forCandidates: [id])
    }
    #endif

    func testRealSignedV3ImportRetainsProvenanceAcrossRestart() async throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let vector = try fresh("all_common")
        let store = try store(name)
        try await store.upsertSignedKEMRefresh(deviceIds: [vector.response.deviceId], payload: vector.response,
            request: vector.request, pinnedProtocolFingerprints: [vector.response.protocolIdentityFingerprint], minimumGeneration: nil)
        let before = await evidence(store, vector.response.deviceId)
        let after = await evidence(try self.store(name), vector.response.deviceId)
        XCTAssertNotNil(before?.negotiation)
        XCTAssertEqual(after?.negotiation, before?.negotiation)
        XCTAssertEqual(after?.suiteWireIds, [0x0001, 0x0012, 0x0101])
        let proof = try XCTUnwrap(after?.negotiation)
        XCTAssertEqual(try proof.select(mode: .init(preference: .mlkem, strictlyMatchSelectedMode: false),
            locallyReadySuites: [0x0012, 0x0001, 0x0101], localQProfile: vector.request.qPeriaptAuthProfile), 0x0012)
    }
    func testAuthenticatedEmptyIntersectionLeavesExistingCacheUnchanged() async throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let vector = try fresh("all_common")
        let store = try store(name)
        try await store.upsertSignedKEMRefresh(deviceIds: [vector.response.deviceId], payload: vector.response,
            request: vector.request, pinnedProtocolFingerprints: [vector.response.protocolIdentityFingerprint], minimumGeneration: nil)
        let before = defaults.data(forKey: cacheKey)
        let empty = try fresh("empty_permitted")
        do {
            try await store.upsertSignedKEMRefresh(deviceIds: [empty.response.deviceId], payload: empty.response,
                request: empty.request, pinnedProtocolFingerprints: [empty.response.protocolIdentityFingerprint], minimumGeneration: nil)
            XCTFail("authenticated no-common is not an import success")
        } catch { XCTAssertEqual(error as? PQCModeSelectionError, .noCommonSuite) }
        XCTAssertEqual(defaults.data(forKey: cacheKey), before)
    }
    func testInvalidSignatureNeverAllocatesCache() async throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let vector = try fresh("native_common")
        var signature = vector.response.signature; signature[signature.startIndex] ^= 1
        let bad = try changed(vector.response, fields: ["signature": signature.base64EncodedString()])
        do {
            try await store(name).upsertSignedKEMRefresh(deviceIds: [bad.deviceId], payload: bad,
                request: vector.request, pinnedProtocolFingerprints: [bad.protocolIdentityFingerprint], minimumGeneration: nil)
            XCTFail("accepted altered ML-DSA signature")
        } catch { XCTAssertNil(defaults.data(forKey: cacheKey)) }
    }
    func testMissingV3ProvenanceIsNotNativeCapabilityEvidence() async throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let vector = try fresh("native_common")
        try await store(name).upsertSignedKEMRefresh(deviceIds: [vector.response.deviceId], payload: vector.response,
            request: vector.request, pinnedProtocolFingerprints: [vector.response.protocolIdentityFingerprint], minimumGeneration: nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: cacheKey))) as? [String: Any])
        #if os(iOS)
        var entries = try XCTUnwrap(object as? [String: [String: Any]])
        #else
        var entries = try XCTUnwrap(object["entries"] as? [String: [String: Any]])
        #endif
        for id in entries.keys { entries[id]?.removeValue(forKey: "negotiation") }
        #if os(iOS)
        object = entries
        #else
        object["entries"] = entries
        #endif
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: cacheKey)
        let after = await evidence(try store(name), vector.response.deviceId)
        XCTAssertNil(after)
    }
}
