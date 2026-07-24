import XCTest
@testable import SkyBridgeCore

final class H264AnnexBAccessUnitTests: XCTestCase {
    func testParsesMixedStartCodesAndBuildsAVCCWithoutParameterSets() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1E])
        let pps = Data([0x68, 0xCE, 0x06, 0xE2])
        let idr = Data([0x65, 0x88, 0x84])
        let accessUnit = try H264AnnexBAccessUnit.parse(
            Data([0, 0, 0, 1]) + sps + Data([0, 0, 1]) + pps + Data([0, 0, 0, 1]) + idr
        )

        XCTAssertEqual(accessUnit.sequenceParameterSet, sps)
        XCTAssertEqual(accessUnit.pictureParameterSet, pps)
        XCTAssertTrue(accessUnit.containsIDR)
        XCTAssertEqual(
            try accessUnit.makeAVCCSampleData(),
            Data([0, 0, 0, UInt8(idr.count)]) + idr
        )
    }

    func testRejectsAccessUnitWithoutLeadingStartCode() {
        XCTAssertThrowsError(try H264AnnexBAccessUnit.parse(Data([0x65, 0x01]))) { error in
            XCTAssertEqual(error as? H264AnnexBAccessUnitError, .missingStartCode)
        }
    }

    func testRejectsPacketizationNALThatShouldHaveBeenDepacketized() {
        XCTAssertThrowsError(
            try H264AnnexBAccessUnit.parse(Data([0, 0, 0, 1, 0x7C, 0x85]))
        ) { error in
            XCTAssertEqual(error as? H264AnnexBAccessUnitError, .invalidNALUnitType(28))
        }
    }

    func testEnforcesNALUnitCountBound() {
        let data = Data([0, 0, 1, 0x61, 0x01, 0, 0, 1, 0x61, 0x02])
        XCTAssertThrowsError(
            try H264AnnexBAccessUnit.parse(data, maximumNALUnitCount: 1)
        ) { error in
            XCTAssertEqual(error as? H264AnnexBAccessUnitError, .tooManyNALUnits(limit: 1))
        }
    }

    func testParameterSetsOnlyAreNotPretendedToBeRenderable() throws {
        let accessUnit = try H264AnnexBAccessUnit.parse(
            Data([0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68, 0xCE])
        )
        XCTAssertThrowsError(try accessUnit.makeAVCCSampleData()) { error in
            XCTAssertEqual(error as? H264AnnexBAccessUnitError, .missingRenderableNALUnit)
        }
    }
}
