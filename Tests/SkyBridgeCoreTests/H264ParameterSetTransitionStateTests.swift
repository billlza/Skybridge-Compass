import XCTest
@testable import SkyBridgeCore

final class H264ParameterSetTransitionStateTests: XCTestCase {
    private let sps1 = Data([0x67, 0x01])
    private let pps1 = Data([0x68, 0x01])
    private let sps2 = Data([0x67, 0x02])
    private let pps2 = Data([0x68, 0x02])

    func testSeparateParameterSetsSwitchAtomicallyAtIDR() throws {
        var state = H264ParameterSetTransitionState()
        state.stage(sequenceParameterSet: sps1, pictureParameterSet: nil)
        XCTAssertNil(state.candidateForIDR(
            carriesSequenceParameterSet: false,
            carriesPictureParameterSet: false,
            containsIDR: true
        ))

        state.stage(sequenceParameterSet: nil, pictureParameterSet: pps1)
        let candidate = try XCTUnwrap(state.candidateForIDR(
            carriesSequenceParameterSet: false,
            carriesPictureParameterSet: false,
            containsIDR: true
        ))
        XCTAssertEqual(candidate, H264ParameterSetPair(
            sequenceParameterSet: sps1,
            pictureParameterSet: pps1
        ))
        state.commit(candidate)
        XCTAssertEqual(state.activePair, candidate)
    }

    func testSingleSPSUpdateDoesNotCombineWithStalePPS() throws {
        var state = H264ParameterSetTransitionState()
        state.stage(sequenceParameterSet: sps1, pictureParameterSet: pps1)
        let initial = try XCTUnwrap(state.candidateForIDR(
            carriesSequenceParameterSet: true,
            carriesPictureParameterSet: true,
            containsIDR: true
        ))
        state.commit(initial)

        state.stage(sequenceParameterSet: sps2, pictureParameterSet: nil)
        XCTAssertNil(state.candidateForIDR(
            carriesSequenceParameterSet: false,
            carriesPictureParameterSet: false,
            containsIDR: true
        ))
        XCTAssertEqual(state.activePair, initial)
    }

    func testExplicitCompletePairAllowsOneSideToRemainUnchanged() throws {
        var state = H264ParameterSetTransitionState()
        state.stage(sequenceParameterSet: sps1, pictureParameterSet: pps1)
        let initial = try XCTUnwrap(state.candidateForIDR(
            carriesSequenceParameterSet: true,
            carriesPictureParameterSet: true,
            containsIDR: true
        ))
        state.commit(initial)

        state.stage(sequenceParameterSet: sps2, pictureParameterSet: pps1)
        let updated = try XCTUnwrap(state.candidateForIDR(
            carriesSequenceParameterSet: true,
            carriesPictureParameterSet: true,
            containsIDR: true
        ))
        XCTAssertEqual(updated.sequenceParameterSet, sps2)
        XCTAssertEqual(updated.pictureParameterSet, pps1)
    }

    func testNonIDRNeverCommitsCompletePendingPair() {
        var state = H264ParameterSetTransitionState()
        state.stage(sequenceParameterSet: sps2, pictureParameterSet: pps2)
        XCTAssertNil(state.candidateForIDR(
            carriesSequenceParameterSet: true,
            carriesPictureParameterSet: true,
            containsIDR: false
        ))
    }
}
