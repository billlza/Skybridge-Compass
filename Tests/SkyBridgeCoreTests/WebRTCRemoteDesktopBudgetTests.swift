import XCTest
@testable import SkyBridgeCore

final class WebRTCRemoteDesktopBudgetTests: XCTestCase {
    func testRelay5KBudgetIsConservative() {
        let budget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 120,
            transportPath: .relay,
            thermalState: .nominal,
            longEdge: 5120,
            lowLatencyMode: false
        )

        XCTAssertEqual(budget.frameRate, 8)
        XCTAssertEqual(budget.maxBufferedAmountBytes, 384_000)
    }

    func testDirect4KBudgetKeepsUsableFrameRate() {
        let budget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 120,
            transportPath: .direct,
            thermalState: .nominal,
            longEdge: 3840,
            lowLatencyMode: false
        )

        XCTAssertEqual(budget.frameRate, 30)
        XCTAssertEqual(budget.maxBufferedAmountBytes, 1_500_000)
    }

    func testDirect5KHevcBudgetUnlocksHighFrameRate() {
        let budget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 120,
            transportPath: .direct,
            thermalState: .nominal,
            longEdge: 5120,
            lowLatencyMode: false,
            codec: .hevc,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            isAppleSilicon: true
        )

        XCTAssertEqual(budget.frameRate, 120)
        XCTAssertEqual(budget.maxBufferedAmountBytes, 2_500_000)
    }

    func testRelayKeepsConservativeBudgetEvenWhenPeerSupportsHevc() {
        let budget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 120,
            transportPath: .relay,
            thermalState: .nominal,
            longEdge: 5120,
            lowLatencyMode: false,
            codec: .hevc,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            isAppleSilicon: true
        )

        XCTAssertEqual(budget.frameRate, 8)
        XCTAssertEqual(budget.maxBufferedAmountBytes, 384_000)
    }

    func testThermalPressureReducesBudgetFurther() {
        let budget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 60,
            transportPath: .relay,
            thermalState: .serious,
            longEdge: 3840,
            lowLatencyMode: false
        )

        XCTAssertEqual(budget.frameRate, 8)
        XCTAssertEqual(budget.maxBufferedAmountBytes, 256_000)
    }
}
