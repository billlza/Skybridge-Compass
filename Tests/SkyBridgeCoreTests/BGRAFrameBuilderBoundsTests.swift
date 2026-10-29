import XCTest
@testable import SkyBridgeCore

final class BGRAFrameBuilderBoundsTests: XCTestCase {
    func testRejectsDimensionAbovePublishedLimitBeforeAllocation() {
        let frame = BGRAFrame(
            data: Data(),
            width: BGRAFrameBuilder.maximumWidth + 1,
            height: 1,
            stride: 0
        )

        XCTAssertThrowsError(try BGRAFrameBuilder.buildPixelBuffer(from: frame, mode: .safeCopy)) { error in
            guard case BGRAFrameBuilderError.invalidDimensions = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsStrideShorterThanVisibleRow() {
        let frame = BGRAFrame(data: Data(repeating: 0, count: 12), width: 4, height: 1, stride: 12)

        XCTAssertThrowsError(try BGRAFrameBuilder.buildPixelBuffer(from: frame, mode: .safeCopy)) { error in
            guard case BGRAFrameBuilderError.invalidStride = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsArithmeticThatWouldExceedFrameBudget() {
        let frame = BGRAFrame(
            data: Data(),
            width: BGRAFrameBuilder.maximumWidth,
            height: BGRAFrameBuilder.maximumHeight,
            stride: BGRAFrameBuilder.maximumFrameBytes
        )

        XCTAssertThrowsError(try BGRAFrameBuilder.buildPixelBuffer(from: frame, mode: .safeCopy)) { error in
            guard case BGRAFrameBuilderError.frameTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
