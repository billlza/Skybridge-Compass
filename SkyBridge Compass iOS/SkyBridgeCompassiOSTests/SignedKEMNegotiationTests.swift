import XCTest
import CryptoKit
import SkyBridgeProtocolCore
@testable import SkyBridgeCompass_iOS

@available(macOS 14.0, iOS 17.0, *)
final class SignedKEMNegotiationTests: XCTestCase {
    private struct Fixture: Decodable { let version: Int; let vectors: [Vector] }
    private struct Vector: Decodable {
        let name: String
        let request: AppMessage.KEMRefreshRequestPayload
        let response: AppMessage.SignedKEMRefreshPayload
        let requestHashHex: String
        let responseHashHex: String
        let selectedSuiteWireId: UInt16?
    }
    private func vectors() throws -> [Vector] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "skr3-golden", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).vectors
    }
    private func validate(_ vector: Vector, response: AppMessage.SignedKEMRefreshPayload? = nil) throws -> AppMessage.SignedKEMRefreshPayload {
        try (response ?? vector.response).validatedForStrictPQCImport(request: vector.request,
            now: vector.request.sentAt, pinnedProtocolFingerprints: [vector.response.protocolIdentityFingerprint],
            minimumGeneration: vector.response.generation)
    }
    private func changed<T: Codable>(_ value: T, field: String, to replacement: Any) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object[field] = replacement
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testIndependentCanonicalVectorsBindCompleteIntersectionAndOrder() throws {
        for vector in try vectors() {
            XCTAssertEqual(vector.request.canonicalRequestHashHex, vector.requestHashHex, vector.name)
            XCTAssertEqual(hash(vector.response.signaturePreimage), vector.responseHashHex, vector.name)
            _ = try vector.request.validatedStrictResponderSuites(now: vector.request.sentAt)
            let response = try validate(vector)
            let permitted = try XCTUnwrap(response.permittedSuiteWireIds)
            let intersection = SignedKEMRefreshNegotiation.intersection(requested: vector.request.requestedSuiteWireIds,
                permitted: permitted, requesterProfile: vector.request.qPeriaptAuthProfile, responderProfile: response.qPeriaptAuthProfile)
            XCTAssertEqual(response.kemPublicKeys.map(\.suiteWireId), intersection.sorted(), vector.name)
            XCTAssertEqual(intersection.first, vector.selectedSuiteWireId, vector.name)
        }
    }

    func testEveryRealMlDsaSignatureIncludingEmptyResultVerifies() async throws {
        let provider = ProtocolSignatureProviderSelector.select(for: .mlDSA65)
        for vector in try vectors() {
            let valid = try await provider.verify(vector.response.signaturePreimage,
                signature: vector.response.signature, publicKey: vector.response.protocolIdentityPublicKey)
            XCTAssertTrue(valid, vector.name)
            _ = try validate(vector)
        }
    }

    func testSemanticallyValidPermittedSetTamperFailsRealSignature() async throws {
        let vector = try XCTUnwrap(vectors().first { $0.name == "strict_q_no_common" })
        let response = try changed(vector.response, field: "permittedSuiteWireIds", to: [1])
        _ = try validate(vector, response: response) // Still a structurally valid, empty intersection.
        let valid = try await ProtocolSignatureProviderSelector.select(for: .mlDSA65).verify(
            response.signaturePreimage, signature: response.signature, publicKey: response.protocolIdentityPublicKey)
        XCTAssertFalse(valid)
    }

    func testEligibleMetadataTamperFailsRealSignature() async throws {
        let vector = try XCTUnwrap(vectors().first)
        let response = try changed(vector.response, field: "osVersion", to: "macOS 26.6")
        _ = try validate(vector, response: response)
        let valid = try await ProtocolSignatureProviderSelector.select(for: .mlDSA65).verify(
            response.signaturePreimage, signature: response.signature, publicKey: response.protocolIdentityPublicKey)
        XCTAssertFalse(valid)
    }

    func testProfileMismatchRemovesOnlyQBeforeChoosingNativeIntersection() throws {
        let vector = try XCTUnwrap(vectors().first { $0.name == "q_profile_mismatch" })
        let response = try validate(vector)
        XCTAssertNotEqual(vector.request.qPeriaptAuthProfile, response.qPeriaptAuthProfile)
        XCTAssertEqual(response.kemPublicKeys.map(\.suiteWireId), [1, 257])
        XCTAssertEqual(vector.selectedSuiteWireId, 1)
    }

    func testMissingDuplicateUnsortedAndForbiddenPermittedSetsFail() throws {
        let vector = try XCTUnwrap(vectors().first)
        for value: Any in [NSNull(), [18, 1, 257], [1, 1, 18, 257], [1, 17, 18, 257], [1, 18, 258], [4097]] {
            XCTAssertThrowsError(try validate(vector, response: changed(vector.response, field: "permittedSuiteWireIds", to: value)))
        }
    }

    func testMissingExtraOrEmptyRawKeysCannotBecomeSuccessfulSubset() throws {
        let vector = try XCTUnwrap(vectors().first)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(vector.response.kemPublicKeys)) as? [[String: Any]])
        for value in [Array(keys.dropFirst()), keys + [keys[0]], [["suiteWireId": 1, "publicKey": ""]]] {
            XCTAssertThrowsError(try validate(vector, response: changed(vector.response, field: "kemPublicKeys", to: value)))
        }
        let empty = try XCTUnwrap(vectors().first { $0.name == "strict_q_no_common" })
        XCTAssertThrowsError(try validate(empty, response: changed(empty.response, field: "kemPublicKeys", to: [["suiteWireId": 1, "publicKey": ""]])))
    }

    func testRequestAndResponseRequireCanonicalMetadata() throws {
        let vector = try XCTUnwrap(vectors().first { $0.name == "native_common" })
        for field in ["platform", "osVersion"] {
            for value: Any in [NSNull(), "", " macOS", "macOS\n26", String(repeating: "a", count: 257)] {
                XCTAssertThrowsError(try validate(vector, response: changed(vector.response, field: field, to: value)))
                let request = try changed(vector.request, field: field, to: value)
                XCTAssertThrowsError(try request.validatedStrictResponderSuites(now: request.sentAt))
            }
        }
    }

    func testQProfileRequiresCanonicalUInt64AndEligiblePlatform() throws {
        let vector = try XCTUnwrap(vectors().first)
        let profile = try XCTUnwrap(vector.request.qPeriaptAuthProfile)
        for value: Any in [NSNull(), profile.uppercased(), profile.replacingOccurrences(of: "/7/", with: "/07/"),
                          profile.replacingOccurrences(of: "/7/", with: "/18446744073709551616/"), profile + " "] {
            let request = try changed(vector.request, field: "qPeriaptAuthProfile", to: value)
            XCTAssertThrowsError(try request.validatedStrictResponderSuites(now: request.sentAt))
        }
        let maxProfile = profile.replacingOccurrences(of: "/7/", with: "/18446744073709551615/")
        let valid = try changed(vector.request, field: "qPeriaptAuthProfile", to: maxProfile)
        _ = try valid.validatedStrictResponderSuites(now: valid.sentAt)
        XCTAssertThrowsError(try validate(vector, response: changed(vector.response, field: "osVersion", to: "macOS 25.0")))
        let native = try XCTUnwrap(vectors().first { $0.name == "native_common" })
        XCTAssertThrowsError(try validate(native, response: changed(native.response, field: "qPeriaptAuthProfile", to: profile)))
    }

    func testSignedEmptyStillRequiresFreshBoundResponse() throws {
        let vector = try XCTUnwrap(vectors().first { $0.name == "strict_q_no_common" })
        XCTAssertTrue(try validate(vector).kemPublicKeys.isEmpty)
        for (field, value): (String, Any) in [("requestNonce", Data(repeating: 0, count: 24).base64EncodedString()),
            ("requestHashHex", String(repeating: "a", count: 64)), ("bonjourEndpointDigest", String(repeating: "b", count: 64)),
            ("generation", 0), ("expiresAt", vector.request.sentAt.timeIntervalSinceReferenceDate),
            ("deviceId", "unrelated-peer"), ("version", 2)] {
            XCTAssertThrowsError(try validate(vector, response: changed(vector.response, field: field, to: value)), field)
        }
    }

    func testLegacyQGoldenCanonicalBytesAndVersionRulesRemainUnchanged() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "skr2-golden", withExtension: "json"))
        struct Legacy: Decodable { let request: AppMessage.KEMRefreshRequestPayload; let response: AppMessage.SignedKEMRefreshPayload; let requestHashHex: String; let responseHashHex: String }
        let legacy = try JSONDecoder().decode(Legacy.self, from: Data(contentsOf: url))
        XCTAssertEqual(legacy.request.canonicalRequestHashHex, legacy.requestHashHex)
        XCTAssertEqual(hash(legacy.response.signaturePreimage), legacy.responseHashHex)
        _ = try legacy.response.validatedForStrictPQCImport(request: legacy.request, now: legacy.request.sentAt,
            pinnedProtocolFingerprints: [legacy.response.protocolIdentityFingerprint])
        let mixed = try changed(legacy.request, field: "requestedSuiteWireIds", to: [1, 18])
        XCTAssertThrowsError(try mixed.validatedStrictResponderSuites(now: mixed.sentAt))
    }
}
