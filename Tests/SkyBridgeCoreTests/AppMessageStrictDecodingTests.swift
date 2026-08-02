import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class AppMessageStrictDecodingTests: XCTestCase {
    private let message = AppMessage.textMessage(
        .init(
            id: UUID(),
            text: "hello",
            sentAt: Date(timeIntervalSinceReferenceDate: 42)
        )
    )

    func testCanonicalAndExactLegacyRepresentationsDecode() throws {
        let canonicalData = try JSONEncoder().encode(message)
        XCTAssertEqual(try AppMessage.decodeWireMessage(from: canonicalData), message)

        let canonicalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )
        let payload = try XCTUnwrap(canonicalObject["textMessage"])
        let legacyData = try JSONSerialization.data(
            withJSONObject: ["textMessage": ["_0": payload]]
        )

        XCTAssertEqual(try AppMessage.decodeWireMessage(from: legacyData), message)
    }

    func testRejectsMissingUnknownAndMultipleDiscriminators() throws {
        let canonicalData = try JSONEncoder().encode(message)
        var canonicalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )
        let payload = try XCTUnwrap(canonicalObject["textMessage"])

        for object: Any in [
            [:] as [String: Any],
            ["futureMessage": [:]] as [String: Any],
            ["textMessage": payload, "ping": ["id": 7]],
        ] {
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: data))
        }

        canonicalObject["futureMessage"] = [:]
        let data = try JSONSerialization.data(withJSONObject: canonicalObject)
        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: data))
    }

    func testSelectedMalformedPayloadCannotFallThroughToAnotherMessageKind() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "textMessage": ["id": "not-a-uuid", "text": "hello", "sentAt": 42],
                "ping": ["id": 7],
            ]
        )

        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: data))
    }

    func testRejectsPayloadThatMixesCurrentAndLegacyRepresentations() throws {
        let canonicalData = try JSONEncoder().encode(message)
        let canonicalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )
        let payload = try XCTUnwrap(canonicalObject["textMessage"] as? [String: Any])
        var mixedPayload = payload
        mixedPayload["_0"] = payload
        let data = try JSONSerialization.data(
            withJSONObject: ["textMessage": mixedPayload]
        )

        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: data))
    }

    func testWireDecoderRejectsDuplicateDiscriminatorAndNestedPayloadKeys() throws {
        let canonicalData = try JSONEncoder().encode(message)
        let canonicalJSON = try XCTUnwrap(String(data: canonicalData, encoding: .utf8))
        XCTAssertTrue(canonicalJSON.hasPrefix("{"))
        XCTAssertTrue(canonicalJSON.hasSuffix("}"))
        let entry = canonicalJSON.dropFirst().dropLast()
        let duplicateDiscriminator = Data("{\(entry),\(entry)}".utf8)

        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: duplicateDiscriminator))

        let messageID = UUID().uuidString
        let duplicateNestedKey = Data(
            #"{"textMessage":{"id":"\#(messageID)","text":"hello","text":"tampered","sentAt":42}}"#.utf8
        )
        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: duplicateNestedKey))
    }

    func testWireDecoderTreatsEscapedAndLiteralDiscriminatorsAsDuplicate() throws {
        let messageID = UUID().uuidString
        let data = Data(
            #"{"textMessage":{"id":"\#(messageID)","text":"one","sentAt":42},"text\u004dessage":{"id":"\#(messageID)","text":"two","sentAt":42}}"#.utf8
        )

        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: data))
    }

    func testWebRTCLegacyNullableEnvelopeRequiresExactlyOnePayload() throws {
        let null = NSNull()
        let legacy: [String: Any] = [
            "clipboard": null,
            "pairingIdentityExchange": null,
            "heartbeat": null,
            "authenticatedRouteBinding": null,
            "ping": ["id": 7],
            "pong": null,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)

        XCTAssertEqual(
            WebRTCControlChannelCodec.decodeCompatibilityAppMessage(data),
            .ping(.init(id: 7))
        )

        var ambiguous = legacy
        ambiguous["pong"] = ["id": 7]
        XCTAssertNil(
            WebRTCControlChannelCodec.decodeCompatibilityAppMessage(
                try JSONSerialization.data(withJSONObject: ambiguous)
            )
        )
    }

    func testWebRTCLegacyEnvelopeRejectsRawDuplicateAndUnknownKeys() {
        let duplicate = Data(
            #"{"ping":{"id":7},"ping":{"id":8},"pong":null}"#.utf8
        )
        let unknown = Data(
            #"{"ping":{"id":7},"futureMessage":null}"#.utf8
        )

        XCTAssertNil(WebRTCControlChannelCodec.decodeCompatibilityAppMessage(duplicate))
        XCTAssertNil(WebRTCControlChannelCodec.decodeCompatibilityAppMessage(unknown))
    }
}
