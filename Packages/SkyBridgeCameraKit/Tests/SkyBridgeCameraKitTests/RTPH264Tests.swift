import Foundation
import XCTest
@testable import SkyBridgeCameraKit

final class RTPH264Tests: XCTestCase {
    func testSingleIDRProducesAnnexBAndInjectsParameterSets() throws {
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data([0x67, 0x42])],
            pictureParameterSets: [Data([0x68, 0xCE])]
        )
        let unit = try XCTUnwrap(depacketizer.consume(packet(
            payload: [0x65, 0xAA], sequence: 10, timestamp: 100, marker: true
        )))
        XCTAssertEqual(unit.data, Data([
            0, 0, 0, 1, 0x67, 0x42,
            0, 0, 0, 1, 0x68, 0xCE,
            0, 0, 0, 1, 0x65, 0xAA,
        ]))
        XCTAssertTrue(unit.isKeyFrame)
        XCTAssertEqual(unit.frameSequenceNumber, 0)
    }

    func testSTAPAAndFUAReassembly() throws {
        var stap = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)
        let stapUnit = try XCTUnwrap(stap.consume(packet(
            payload: [0x78, 0, 2, 0x61, 1, 0, 3, 0x65, 2, 3],
            sequence: 1,
            timestamp: 50,
            marker: true
        )))
        XCTAssertEqual(stapUnit.data, Data([
            0, 0, 0, 1, 0x61, 1,
            0, 0, 0, 1, 0x65, 2, 3,
        ]))
        XCTAssertTrue(stapUnit.isKeyFrame)

        var fua = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)
        XCTAssertNil(try fua.consume(packet(
            payload: [0x7C, 0x85, 0xAA], sequence: 20, timestamp: 80, marker: false
        )))
        let fuUnit = try XCTUnwrap(fua.consume(packet(
            payload: [0x7C, 0x45, 0xBB, 0xCC], sequence: 21, timestamp: 80, marker: true
        )))
        XCTAssertEqual(fuUnit.data, Data([0, 0, 0, 1, 0x65, 0xAA, 0xBB, 0xCC]))
    }

    func testSTAPAHandlesNonZeroStartIndexPayloadAndRejectsTruncatedSlice() throws {
        let payload = nonZeroStartIndexSlice(
            Data([0x78, 0, 2, 0x61, 1, 0, 3, 0x65, 2, 3]),
            prefixCount: 3
        )
        XCTAssertEqual(payload.startIndex, 3)

        var depacketizer = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)
        let unit = try XCTUnwrap(depacketizer.consume(RTPPacket(
            marker: true,
            payloadType: 96,
            sequenceNumber: 1,
            timestamp: 50,
            sourceIdentifier: 1,
            payload: payload
        )))
        XCTAssertEqual(unit.data, annexB([[0x61, 1], [0x65, 2, 3]]))

        let truncatedPayload = nonZeroStartIndexSlice(
            Data([0x78, 0, 3, 0x65, 0xAA]),
            prefixCount: 4
        )
        var malformed = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)
        XCTAssertThrowsError(try malformed.consume(RTPPacket(
            marker: true,
            payloadType: 96,
            sequenceNumber: 1,
            timestamp: 50,
            sourceIdentifier: 1,
            payload: truncatedPayload
        )))
    }

    func testFUAHandlesNonZeroStartIndexPayloadsAndRejectsTruncatedSlice() throws {
        let startPayload = nonZeroStartIndexSlice(Data([0x7C, 0x85, 0xAA]), prefixCount: 2)
        let endPayload = nonZeroStartIndexSlice(
            Data([0x7C, 0x45, 0xBB, 0xCC]),
            prefixCount: 5
        )
        XCTAssertEqual(startPayload.startIndex, 2)
        XCTAssertEqual(endPayload.startIndex, 5)

        var depacketizer = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)
        XCTAssertNil(try depacketizer.consume(RTPPacket(
            marker: false,
            payloadType: 96,
            sequenceNumber: 20,
            timestamp: 80,
            sourceIdentifier: 1,
            payload: startPayload
        )))
        let unit = try XCTUnwrap(depacketizer.consume(RTPPacket(
            marker: true,
            payloadType: 96,
            sequenceNumber: 21,
            timestamp: 80,
            sourceIdentifier: 1,
            payload: endPayload
        )))
        XCTAssertEqual(unit.data, annexB([[0x65, 0xAA, 0xBB, 0xCC]]))

        let truncatedPayload = nonZeroStartIndexSlice(Data([0x7C, 0x85]), prefixCount: 6)
        var malformed = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)
        XCTAssertThrowsError(try malformed.consume(RTPPacket(
            marker: false,
            payloadType: 96,
            sequenceNumber: 1,
            timestamp: 80,
            sourceIdentifier: 1,
            payload: truncatedPayload
        )))
    }

    func testSequenceWrapIsAcceptedAndFramesRemainMonotonic() throws {
        var depacketizer = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)
        let first = try XCTUnwrap(depacketizer.consume(packet(
            payload: [0x65, 1], sequence: .max, timestamp: 1, marker: true
        )))
        let second = try XCTUnwrap(depacketizer.consume(packet(
            payload: [0x61, 2], sequence: 0, timestamp: 2, marker: true
        )))
        XCTAssertEqual(first.frameSequenceNumber, 0)
        XCTAssertEqual(second.frameSequenceNumber, 1)
    }

    func testSeparateInBandParameterSetAccessUnitsAreInjectedIntoFollowingIDR() throws {
        var depacketizer = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)
        let spsUnit = try XCTUnwrap(depacketizer.consume(packet(
            payload: [0x67, 0x42, 0x01], sequence: 1, timestamp: 1, marker: true
        )))
        let ppsUnit = try XCTUnwrap(depacketizer.consume(packet(
            payload: [0x68, 0xCE, 0x02], sequence: 2, timestamp: 2, marker: true
        )))
        XCTAssertFalse(spsUnit.containsVideoCodingLayer)
        XCTAssertFalse(ppsUnit.containsVideoCodingLayer)
        XCTAssertEqual(spsUnit.frameSequenceNumber, 0)
        XCTAssertEqual(ppsUnit.frameSequenceNumber, 0)

        let idr = try XCTUnwrap(depacketizer.consume(packet(
            payload: [0x65, 0xAA], sequence: 3, timestamp: 3, marker: true
        )))
        XCTAssertEqual(idr.data, Data([
            0, 0, 0, 1, 0x67, 0x42, 0x01,
            0, 0, 0, 1, 0x68, 0xCE, 0x02,
            0, 0, 0, 1, 0x65, 0xAA,
        ]))
        XCTAssertTrue(idr.containsVideoCodingLayer)
        XCTAssertEqual(idr.frameSequenceNumber, 0)

        let predictive = try XCTUnwrap(depacketizer.consume(packet(
            payload: [0x61, 0xBB], sequence: 4, timestamp: 4, marker: true
        )))
        XCTAssertEqual(predictive.frameSequenceNumber, 1)
    }

    func testRepeatedActiveParameterSetAccessUnitsDoNotCreateVideoFrameSequenceGap() throws {
        let activeSPS: [UInt8] = [0x67, 0x42, 0x01]
        let activePPS: [UInt8] = [0x68, 0xCE, 0x01]
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(activeSPS)],
            pictureParameterSets: [Data(activePPS)]
        )

        let idr = try XCTUnwrap(depacketizer.consume(packet(
            payload: [0x65, 0xAA], sequence: 10, timestamp: 10, marker: true
        )))
        let repeatedSPS = try XCTUnwrap(depacketizer.consume(packet(
            payload: activeSPS, sequence: 11, timestamp: 11, marker: true
        )))
        let repeatedPPS = try XCTUnwrap(depacketizer.consume(packet(
            payload: activePPS, sequence: 12, timestamp: 12, marker: true
        )))
        let predictive = try XCTUnwrap(depacketizer.consume(packet(
            payload: [0x61, 0xBB], sequence: 13, timestamp: 13, marker: true
        )))

        XCTAssertEqual(idr.frameSequenceNumber, 0)
        XCTAssertFalse(repeatedSPS.containsVideoCodingLayer)
        XCTAssertFalse(repeatedPPS.containsVideoCodingLayer)
        XCTAssertEqual(repeatedSPS.frameSequenceNumber, 1)
        XCTAssertEqual(repeatedPPS.frameSequenceNumber, 1)
        XCTAssertEqual(predictive.frameSequenceNumber, 1)
    }

    func testChangedSPSWithIDRIsDroppedUntilNewPPSCommitsAtomically() throws {
        let oldSPS: [UInt8] = [0x67, 0x42, 0x01]
        let oldPPS: [UInt8] = [0x68, 0xCE, 0x01]
        let newSPS: [UInt8] = [0x67, 0x64, 0x02]
        let newPPS: [UInt8] = [0x68, 0xEE, 0x02]
        let idr: [UInt8] = [0x65, 0xAA]
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(oldSPS)],
            pictureParameterSets: [Data(oldPPS)]
        )

        XCTAssertNil(try depacketizer.consume(packet(
            payload: stapA([newSPS, idr]),
            sequence: 1,
            timestamp: 1,
            marker: true
        )))
        let ppsOnly = try XCTUnwrap(depacketizer.consume(packet(
            payload: newPPS,
            sequence: 2,
            timestamp: 2,
            marker: true
        )))
        XCTAssertEqual(ppsOnly.data, annexB([newPPS]))

        let recovered = try XCTUnwrap(depacketizer.consume(packet(
            payload: idr,
            sequence: 3,
            timestamp: 3,
            marker: true
        )))
        XCTAssertEqual(recovered.data, annexB([newSPS, newPPS, idr]))
    }

    func testChangedPPSWithIDRIsDroppedUntilNewSPSCommitsAtomically() throws {
        let oldSPS: [UInt8] = [0x67, 0x42, 0x01]
        let oldPPS: [UInt8] = [0x68, 0xCE, 0x01]
        let newSPS: [UInt8] = [0x67, 0x64, 0x02]
        let newPPS: [UInt8] = [0x68, 0xEE, 0x02]
        let idr: [UInt8] = [0x65, 0xBB]
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(oldSPS)],
            pictureParameterSets: [Data(oldPPS)]
        )

        XCTAssertNil(try depacketizer.consume(packet(
            payload: stapA([newPPS, idr]),
            sequence: 10,
            timestamp: 10,
            marker: true
        )))
        let spsOnly = try XCTUnwrap(depacketizer.consume(packet(
            payload: newSPS,
            sequence: 11,
            timestamp: 11,
            marker: true
        )))
        XCTAssertEqual(spsOnly.data, annexB([newSPS]))

        let recovered = try XCTUnwrap(depacketizer.consume(packet(
            payload: idr,
            sequence: 12,
            timestamp: 12,
            marker: true
        )))
        XCTAssertEqual(recovered.data, annexB([newSPS, newPPS, idr]))
    }

    func testPendingSPSRejectsRepeatedActivePPSAsCrossAccessUnitCompletion() throws {
        let oldSPS: [UInt8] = [0x67, 0x42, 0x01]
        let oldPPS: [UInt8] = [0x68, 0xCE, 0x01]
        let newSPS: [UInt8] = [0x67, 0x64, 0x02]
        let newPPS: [UInt8] = [0x68, 0xEE, 0x02]
        let idr: [UInt8] = [0x65, 0xBC]
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(oldSPS)],
            pictureParameterSets: [Data(oldPPS)]
        )

        XCTAssertNil(try depacketizer.consume(packet(
            payload: stapA([newSPS, idr]),
            sequence: 13,
            timestamp: 13,
            marker: true
        )))
        XCTAssertNil(try depacketizer.consume(packet(
            payload: stapA([oldPPS, idr]),
            sequence: 14,
            timestamp: 14,
            marker: true
        )))

        let recovered = try XCTUnwrap(depacketizer.consume(packet(
            payload: stapA([newPPS, idr]),
            sequence: 15,
            timestamp: 15,
            marker: true
        )))
        XCTAssertEqual(recovered.data, annexB([newSPS, newPPS, idr]))
    }

    func testPendingPPSRejectsRepeatedActiveSPSAsCrossAccessUnitCompletion() throws {
        let oldSPS: [UInt8] = [0x67, 0x42, 0x01]
        let oldPPS: [UInt8] = [0x68, 0xCE, 0x01]
        let newSPS: [UInt8] = [0x67, 0x64, 0x02]
        let newPPS: [UInt8] = [0x68, 0xEE, 0x02]
        let idr: [UInt8] = [0x65, 0xBD]
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(oldSPS)],
            pictureParameterSets: [Data(oldPPS)]
        )

        XCTAssertNil(try depacketizer.consume(packet(
            payload: stapA([newPPS, idr]),
            sequence: 16,
            timestamp: 16,
            marker: true
        )))
        XCTAssertNil(try depacketizer.consume(packet(
            payload: stapA([oldSPS, idr]),
            sequence: 17,
            timestamp: 17,
            marker: true
        )))

        let recovered = try XCTUnwrap(depacketizer.consume(packet(
            payload: stapA([newSPS, idr]),
            sequence: 18,
            timestamp: 18,
            marker: true
        )))
        XCTAssertEqual(recovered.data, annexB([newPPS, newSPS, idr]))
    }

    func testIncompleteTransitionDropsBareIDRAndPredictiveFramesUntilCompletingIDR() throws {
        let oldSPS: [UInt8] = [0x67, 0x42, 0x01]
        let oldPPS: [UInt8] = [0x68, 0xCE, 0x01]
        let newSPS: [UInt8] = [0x67, 0x64, 0x02]
        let newPPS: [UInt8] = [0x68, 0xEE, 0x02]
        let idr: [UInt8] = [0x65, 0xCC]
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(oldSPS)],
            pictureParameterSets: [Data(oldPPS)]
        )

        let spsOnly = try XCTUnwrap(depacketizer.consume(packet(
            payload: newSPS,
            sequence: 20,
            timestamp: 20,
            marker: true
        )))
        XCTAssertEqual(spsOnly.data, annexB([newSPS]))
        XCTAssertNil(try depacketizer.consume(packet(
            payload: idr,
            sequence: 21,
            timestamp: 21,
            marker: true
        )))
        XCTAssertNil(try depacketizer.consume(packet(
            payload: [0x61, 0xDD],
            sequence: 22,
            timestamp: 22,
            marker: true
        )))

        let recovered = try XCTUnwrap(depacketizer.consume(packet(
            payload: stapA([newPPS, idr]),
            sequence: 23,
            timestamp: 23,
            marker: true
        )))
        XCTAssertEqual(recovered.data, annexB([newSPS, newPPS, idr]))
    }

    func testCompleteNewPairWithPredictiveFrameWaitsForIDR() throws {
        let oldSPS: [UInt8] = [0x67, 0x42, 0x01]
        let oldPPS: [UInt8] = [0x68, 0xCE, 0x01]
        let newSPS: [UInt8] = [0x67, 0x64, 0x02]
        let newPPS: [UInt8] = [0x68, 0xEE, 0x02]
        let predictiveFrame: [UInt8] = [0x61, 0x10]
        let idr: [UInt8] = [0x65, 0x11]
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(oldSPS)],
            pictureParameterSets: [Data(oldPPS)]
        )

        XCTAssertNil(try depacketizer.consume(packet(
            payload: stapA([newSPS, newPPS, predictiveFrame]),
            sequence: 24,
            timestamp: 24,
            marker: true
        )))
        XCTAssertNil(try depacketizer.consume(packet(
            payload: predictiveFrame,
            sequence: 25,
            timestamp: 25,
            marker: true
        )))

        let recovered = try XCTUnwrap(depacketizer.consume(packet(
            payload: idr,
            sequence: 26,
            timestamp: 26,
            marker: true
        )))
        XCTAssertEqual(recovered.data, annexB([newSPS, newPPS, idr]))
    }

    func testCrossAccessUnitPairCompletedWithPredictiveFrameWaitsForIDR() throws {
        let oldSPS: [UInt8] = [0x67, 0x42, 0x01]
        let oldPPS: [UInt8] = [0x68, 0xCE, 0x01]
        let newSPS: [UInt8] = [0x67, 0x64, 0x02]
        let newPPS: [UInt8] = [0x68, 0xEE, 0x02]
        let predictiveFrame: [UInt8] = [0x61, 0x20]
        let idr: [UInt8] = [0x65, 0x21]
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(oldSPS)],
            pictureParameterSets: [Data(oldPPS)]
        )

        let spsOnly = try XCTUnwrap(depacketizer.consume(packet(
            payload: newSPS,
            sequence: 27,
            timestamp: 27,
            marker: true
        )))
        XCTAssertEqual(spsOnly.data, annexB([newSPS]))
        XCTAssertNil(try depacketizer.consume(packet(
            payload: stapA([newPPS, predictiveFrame]),
            sequence: 28,
            timestamp: 28,
            marker: true
        )))

        let recovered = try XCTUnwrap(depacketizer.consume(packet(
            payload: idr,
            sequence: 29,
            timestamp: 29,
            marker: true
        )))
        XCTAssertEqual(recovered.data, annexB([newSPS, newPPS, idr]))
    }

    func testPartialParameterSetWithoutActivePairDoesNotPublishVCL() throws {
        let newSPS: [UInt8] = [0x67, 0x64, 0x02]
        let newPPS: [UInt8] = [0x68, 0xEE, 0x02]
        let idr: [UInt8] = [0x65, 0xDD]
        var depacketizer = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)

        XCTAssertNil(try depacketizer.consume(packet(
            payload: stapA([newSPS, idr]),
            sequence: 30,
            timestamp: 30,
            marker: true
        )))
        XCTAssertNil(try depacketizer.consume(packet(
            payload: [0x61, 0x01],
            sequence: 31,
            timestamp: 31,
            marker: true
        )))

        let recovered = try XCTUnwrap(depacketizer.consume(packet(
            payload: stapA([newPPS, idr]),
            sequence: 32,
            timestamp: 32,
            marker: true
        )))
        XCTAssertEqual(recovered.data, annexB([newSPS, newPPS, idr]))
    }

    func testSequenceDiscontinuityAndSSRCChangeDiscardIncompleteParameterSets() throws {
        let oldSPS: [UInt8] = [0x67, 0x42, 0x01]
        let oldPPS: [UInt8] = [0x68, 0xCE, 0x01]
        let newSPS: [UInt8] = [0x67, 0x64, 0x02]
        let newPPS: [UInt8] = [0x68, 0xEE, 0x02]
        let idr: [UInt8] = [0x65, 0xDE]

        var discontinuity = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(oldSPS)],
            pictureParameterSets: [Data(oldPPS)]
        )
        _ = try discontinuity.consume(packet(
            payload: newSPS,
            sequence: 50,
            timestamp: 50,
            marker: true
        ))
        XCTAssertThrowsError(try discontinuity.consume(packet(
            payload: newPPS,
            sequence: 52,
            timestamp: 52,
            marker: true
        ))) {
            XCTAssertEqual(
                $0 as? SkyBridgeCameraError,
                .rtpSequenceDiscontinuity(expected: 51, actual: 52)
            )
        }
        XCTAssertNil(try discontinuity.consume(packet(
            payload: stapA([newPPS, idr]),
            sequence: 53,
            timestamp: 53,
            marker: true
        )))

        var changedSSRC = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(oldSPS)],
            pictureParameterSets: [Data(oldPPS)]
        )
        _ = try changedSSRC.consume(packet(
            payload: newSPS,
            sequence: 60,
            timestamp: 60,
            marker: true,
            ssrc: 1
        ))
        XCTAssertThrowsError(try changedSSRC.consume(packet(
            payload: newPPS,
            sequence: 61,
            timestamp: 61,
            marker: true,
            ssrc: 2
        )))
        XCTAssertNil(try changedSSRC.consume(packet(
            payload: stapA([newPPS, idr]),
            sequence: 62,
            timestamp: 62,
            marker: true,
            ssrc: 2
        )))
    }

    func testMalformedAndOversizedPacketsDiscardIncompleteParameterSets() throws {
        let oldSPS: [UInt8] = [0x67, 0x42, 0x01]
        let oldPPS: [UInt8] = [0x68, 0xCE, 0x01]
        let newSPS: [UInt8] = [0x67, 0x64, 0x02]
        let newPPS: [UInt8] = [0x68, 0xEE, 0x02]
        let idr: [UInt8] = [0x65, 0xDF]

        var malformed = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(oldSPS)],
            pictureParameterSets: [Data(oldPPS)]
        )
        _ = try malformed.consume(packet(
            payload: newSPS,
            sequence: 70,
            timestamp: 70,
            marker: true
        ))
        XCTAssertThrowsError(try malformed.consume(Data([0x80])))
        XCTAssertNil(try malformed.consume(packet(
            payload: stapA([newPPS, idr]),
            sequence: 71,
            timestamp: 71,
            marker: true
        )))

        var oversized = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(oldSPS)],
            pictureParameterSets: [Data(oldPPS)],
            maximumAccessUnitBytes: 32
        )
        _ = try oversized.consume(packet(
            payload: newSPS,
            sequence: 80,
            timestamp: 80,
            marker: true
        ))
        XCTAssertThrowsError(try oversized.consume(packet(
            payload: [0x61] + Array(repeating: 0xAA, count: 32),
            sequence: 81,
            timestamp: 81,
            marker: true
        ))) {
            XCTAssertEqual($0 as? SkyBridgeCameraError, .accessUnitTooLarge(limit: 32))
        }
        XCTAssertNil(try oversized.consume(packet(
            payload: stapA([newPPS, idr]),
            sequence: 82,
            timestamp: 82,
            marker: true
        )))
    }

    func testRepeatedActiveSPSDoesNotStartAParameterSetTransition() throws {
        let activeSPS: [UInt8] = [0x67, 0x42, 0x01]
        let activePPS: [UInt8] = [0x68, 0xCE, 0x01]
        let idr: [UInt8] = [0x65, 0xEE]
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            sequenceParameterSets: [Data(activeSPS)],
            pictureParameterSets: [Data(activePPS)]
        )

        let unit = try XCTUnwrap(depacketizer.consume(packet(
            payload: stapA([activeSPS, idr]),
            sequence: 40,
            timestamp: 40,
            marker: true
        )))
        XCTAssertEqual(unit.data, annexB([activePPS, activeSPS, idr]))

        let bareIDR = try XCTUnwrap(depacketizer.consume(packet(
            payload: idr,
            sequence: 41,
            timestamp: 41,
            marker: true
        )))
        XCTAssertEqual(bareIDR.data, annexB([activeSPS, activePPS, idr]))
    }

    func testRejectsDiscontinuitySSRCChangeForbiddenBitAndModeViolation() throws {
        var discontinuity = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)
        XCTAssertNil(try discontinuity.consume(packet(
            payload: [0x61, 1], sequence: 1, timestamp: 1, marker: false
        )))
        XCTAssertThrowsError(try discontinuity.consume(packet(
            payload: [0x61, 2], sequence: 3, timestamp: 1, marker: true
        ))) {
            XCTAssertEqual(
                $0 as? SkyBridgeCameraError,
                .rtpSequenceDiscontinuity(expected: 2, actual: 3)
            )
        }

        var ssrc = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)
        _ = try ssrc.consume(packet(
            payload: [0x61, 1], sequence: 1, timestamp: 1, marker: true, ssrc: 1
        ))
        XCTAssertThrowsError(try ssrc.consume(packet(
            payload: [0x61, 2], sequence: 2, timestamp: 2, marker: true, ssrc: 2
        )))

        var forbidden = H264RTPDepacketizer(payloadType: 96, packetizationMode: 1)
        XCTAssertThrowsError(try forbidden.consume(packet(
            payload: [0xE1, 1], sequence: 1, timestamp: 1, marker: true
        )))

        var modeZero = H264RTPDepacketizer(payloadType: 96, packetizationMode: 0)
        XCTAssertThrowsError(try modeZero.consume(packet(
            payload: [0x78, 0, 2, 0x61, 1], sequence: 1, timestamp: 1, marker: true
        )))
    }

    func testFUAStartIncludesExistingAccessUnitInSizeBound() throws {
        var depacketizer = H264RTPDepacketizer(
            payloadType: 96,
            packetizationMode: 1,
            maximumAccessUnitBytes: 16
        )
        XCTAssertNil(try depacketizer.consume(packet(
            payload: [0x61, 1, 2, 3, 4, 5, 6],
            sequence: 1,
            timestamp: 1,
            marker: false
        )))
        XCTAssertThrowsError(try depacketizer.consume(packet(
            payload: [0x7C, 0x85, 1, 2, 3, 4, 5],
            sequence: 2,
            timestamp: 1,
            marker: false
        ))) {
            XCTAssertEqual($0 as? SkyBridgeCameraError, .accessUnitTooLarge(limit: 16))
        }
    }

    func testRTPParserHandlesCSRCHeaderExtensionAndPadding() throws {
        var bytes = Data([
            0xB1, 0xE0, 0, 7,
            0, 0, 0, 9,
            0, 0, 0, 1,
            0, 0, 0, 2,
            0xBE, 0xDE, 0, 1,
            1, 2, 3, 4,
            0x61, 0xAA,
            0, 2,
        ])
        let slice = nonZeroStartIndexSlice(bytes, prefixCount: 5)
        XCTAssertEqual(slice.startIndex, 5)
        let parsed = try RTPPacket.parse(slice)
        XCTAssertTrue(parsed.marker)
        XCTAssertEqual(parsed.sequenceNumber, 7)
        XCTAssertEqual(parsed.payload, Data([0x61, 0xAA]))

        XCTAssertThrowsError(try RTPPacket.parse(slice.prefix(15)))
        XCTAssertThrowsError(try RTPPacket.parse(slice.prefix(19)))
        XCTAssertThrowsError(try RTPPacket.parse(slice.prefix(23)))
        XCTAssertThrowsError(try RTPPacket.parse(slice.dropLast()))

        bytes[0] = 0x31
        XCTAssertThrowsError(try RTPPacket.parse(bytes))
    }

    func testRTPParserHandlesOrdinaryNonZeroStartIndexPacketAndRejectsTruncatedHeaderSlice()
        throws
    {
        let encoded = packet(
            payload: [0x61, 0xAA],
            sequence: 0x1234,
            timestamp: 0x1020_3040,
            marker: true,
            ssrc: 0x5060_7080
        )
        let slice = nonZeroStartIndexSlice(encoded, prefixCount: 4)

        XCTAssertEqual(slice.startIndex, 4)
        let parsed = try RTPPacket.parse(slice)
        XCTAssertTrue(parsed.marker)
        XCTAssertEqual(parsed.payloadType, 96)
        XCTAssertEqual(parsed.sequenceNumber, 0x1234)
        XCTAssertEqual(parsed.timestamp, 0x1020_3040)
        XCTAssertEqual(parsed.sourceIdentifier, 0x5060_7080)
        XCTAssertEqual(parsed.payload, Data([0x61, 0xAA]))
        XCTAssertThrowsError(try RTPPacket.parse(slice.prefix(11)))
    }

    private func packet(
        payload: [UInt8],
        sequence: UInt16,
        timestamp: UInt32,
        marker: Bool,
        ssrc: UInt32 = 1
    ) -> Data {
        var data = Data([
            0x80,
            marker ? 0xE0 : 0x60,
            UInt8(sequence >> 8), UInt8(sequence & 0xFF),
            UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xFF),
            UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF),
            UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xFF),
            UInt8((ssrc >> 8) & 0xFF), UInt8(ssrc & 0xFF),
        ])
        data.append(contentsOf: payload)
        return data
    }

    private func stapA(_ nalUnits: [[UInt8]]) -> [UInt8] {
        var payload: [UInt8] = [0x78]
        for nalUnit in nalUnits {
            payload.append(UInt8((nalUnit.count >> 8) & 0xFF))
            payload.append(UInt8(nalUnit.count & 0xFF))
            payload.append(contentsOf: nalUnit)
        }
        return payload
    }

    private func nonZeroStartIndexSlice(_ data: Data, prefixCount: Int) -> Data {
        precondition(prefixCount > 0)
        var storage = Data(repeating: 0xA5, count: prefixCount)
        storage.append(data)
        storage.append(0x5A)
        let start = storage.index(storage.startIndex, offsetBy: prefixCount)
        let end = storage.index(start, offsetBy: data.count)
        return storage[start..<end]
    }

    private func annexB(_ nalUnits: [[UInt8]]) -> Data {
        var data = Data()
        for nalUnit in nalUnits {
            data.append(contentsOf: [0, 0, 0, 1])
            data.append(contentsOf: nalUnit)
        }
        return data
    }
}
