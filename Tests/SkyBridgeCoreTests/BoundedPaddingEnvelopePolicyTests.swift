import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@available(macOS 14.0, *)
final class BoundedPaddingEnvelopePolicyTests: XCTestCase {
    func testDisabledPlanStillEnforcesTransportCeiling() throws {
        let exact = try BoundedPaddingEnvelopePolicy.plan(
            payloadByteCount: 64,
            headerByteCount: 8,
            enabled: false,
            target: .fixed(Int.max),
            maximumOutputByteCount: 64
        )
        XCTAssertEqual(exact, .init(shouldWrap: false, totalByteCount: 64))

        XCTAssertThrowsError(
            try BoundedPaddingEnvelopePolicy.plan(
                payloadByteCount: 65,
                headerByteCount: 8,
                enabled: false,
                target: .fixed(0),
                maximumOutputByteCount: 64
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundedPaddingEnvelopePolicyError,
                .payloadExceedsMaximum(actual: 65, maximum: 64)
            )
        }
    }

    func testEnabledPlanChecksEnvelopeLengthBeforeAllocation() throws {
        let exact = try BoundedPaddingEnvelopePolicy.plan(
            payloadByteCount: 56,
            headerByteCount: 8,
            enabled: true,
            target: .fixed(64),
            maximumOutputByteCount: 64
        )
        XCTAssertEqual(exact, .init(shouldWrap: true, totalByteCount: 64))

        XCTAssertThrowsError(
            try BoundedPaddingEnvelopePolicy.plan(
                payloadByteCount: 57,
                headerByteCount: 8,
                enabled: true,
                target: .fixed(64),
                maximumOutputByteCount: 64
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundedPaddingEnvelopePolicyError,
                .minimumEnvelopeExceedsMaximum(required: 65, maximum: 64)
            )
        }
    }

    func testExtremeAndTooSmallFixedTargetsFailExplicitly() {
        XCTAssertThrowsError(
            try BoundedPaddingEnvelopePolicy.plan(
                payloadByteCount: 1,
                headerByteCount: 8,
                enabled: true,
                target: .fixed(Int.max),
                maximumOutputByteCount: 64
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundedPaddingEnvelopePolicyError,
                .invalidPaddingTarget(actual: Int.max, maximum: 64)
            )
        }

        XCTAssertThrowsError(
            try BoundedPaddingEnvelopePolicy.plan(
                payloadByteCount: 57,
                headerByteCount: 8,
                enabled: true,
                target: .fixed(60),
                maximumOutputByteCount: 128
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundedPaddingEnvelopePolicyError,
                .payloadExceedsFixedPaddingTarget(required: 65, configured: 60)
            )
        }
    }

    func testMalformedBucketCannotHideBehindSmallerPayload() {
        XCTAssertThrowsError(
            try BoundedPaddingEnvelopePolicy.plan(
                payloadByteCount: 1,
                headerByteCount: 8,
                enabled: true,
                target: .bucketed([16, Int.max]),
                maximumOutputByteCount: 64
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundedPaddingEnvelopePolicyError,
                .invalidPaddingTarget(actual: Int.max, maximum: 64)
            )
        }
    }

    func testPreferredPaddingCeilingDoesNotBecomeAFalsePayloadLimit() throws {
        let plan = try BoundedPaddingEnvelopePolicy.plan(
            payloadByteCount: 8_200,
            headerByteCount: 8,
            enabled: true,
            target: .bucketed([8_192, 16_384]),
            maximumOutputByteCount: 16_392,
            maximumPaddingTargetByteCount: 8_188
        )
        XCTAssertEqual(plan, .init(shouldWrap: true, totalByteCount: 8_208))

        XCTAssertThrowsError(
            try BoundedPaddingEnvelopePolicy.plan(
                payloadByteCount: 1,
                headerByteCount: 8,
                enabled: true,
                target: .fixed(8_192),
                maximumOutputByteCount: 16_392,
                maximumPaddingTargetByteCount: 8_188
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundedPaddingEnvelopePolicyError,
                .invalidPaddingTarget(actual: 8_192, maximum: 8_188)
            )
        }
    }

    func testTrafficPaddingUsesBoundedPlanAndRoundTrips() throws {
        let configuration = TrafficPaddingConfig(
            enabled: true,
            debugLog: false,
            mode: .fixed,
            fixedSizeBytes: 64,
            bucketSizesBytes: []
        )
        let payload = Data(repeating: 0xA5, count: 16)
        let wrapped = try TrafficPadding.wrapIfEnabled(
            payload,
            configuration: configuration,
            maximumOutputByteCount: 64
        )
        XCTAssertEqual(wrapped.count, 64)
        XCTAssertEqual(TrafficPadding.unwrapIfNeeded(wrapped), payload)

        let invalidConfiguration = TrafficPaddingConfig(
            enabled: true,
            debugLog: false,
            mode: .fixed,
            fixedSizeBytes: Int.max,
            bucketSizesBytes: []
        )
        XCTAssertThrowsError(
            try TrafficPadding.wrapIfEnabled(
                Data([0x01]),
                configuration: invalidConfiguration,
                maximumOutputByteCount: 64
            )
        )
    }

    func testHandshakePaddingHonorsProtocolAndPreferredCeilings() throws {
        let configuration = HandshakePaddingConfig(
            enabled: true,
            debugLog: false,
            mode: .bucketed,
            fixedSizeBytes: 0,
            bucketSizesBytes: [256, 512, 1_024, 2_048, 4_096, 8_192, 16_384]
        )
        let payload = Data(repeating: 0x5A, count: 8_200)
        let wrapped = try HandshakePadding.wrapIfEnabled(
            payload,
            configuration: configuration,
            maximumPaddingTargetByteCount: 8_188
        )
        XCTAssertEqual(wrapped.count, payload.count + 8)
        XCTAssertEqual(HandshakePadding.unwrapIfNeeded(wrapped), payload)

        XCTAssertThrowsError(
            try HandshakePadding.wrapIfEnabled(
                Data(repeating: 0, count: HandshakePadding.maximumOutputByteCount),
                configuration: configuration
            )
        )
    }

    func testOversizedRecognizedHandshakeEnvelopeIsNotUnwrappedIntoABody() {
        var oversizedEnvelope = Data([0x53, 0x42, 0x50, 0x31])
        let declaredBodyByteCount = HandshakePadding.maximumOutputByteCount - 8 + 1
        var declaredLength = UInt32(declaredBodyByteCount).bigEndian
        withUnsafeBytes(of: &declaredLength) {
            oversizedEnvelope.append(contentsOf: $0)
        }
        oversizedEnvelope.append(
            Data(repeating: 0xA5, count: declaredBodyByteCount)
        )

        XCTAssertEqual(
            HandshakePadding.unwrapIfNeeded(oversizedEnvelope),
            oversizedEnvelope
        )
    }
}
