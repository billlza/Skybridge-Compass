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

    func testRelayNativeRTPBudgetAllowsInteractiveFrameRate() {
        let budget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 60,
            transportPath: .relay,
            thermalState: .nominal,
            longEdge: 1920,
            lowLatencyMode: true,
            codec: .h264,
            nativeVideoTrackEnabled: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            isAppleSilicon: true
        )

        XCTAssertEqual(budget.frameRate, 60)
        XCTAssertEqual(budget.maxBufferedAmountBytes, 1_280_000)
        XCTAssertEqual(budget.reason, "relay-native-rtp")
    }

    func testRelayNativeRTP4KLowLatencyBudgetAllowsSixtyFPSOnAppleSilicon() {
        let budget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 60,
            transportPath: .relay,
            thermalState: .nominal,
            longEdge: 3840,
            lowLatencyMode: true,
            codec: .h264,
            nativeVideoTrackEnabled: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            isAppleSilicon: true
        )

        XCTAssertEqual(budget.frameRate, 60)
        XCTAssertEqual(budget.maxBufferedAmountBytes, 1_280_000)
        XCTAssertEqual(budget.reason, "relay-native-rtp")
    }

    func testRelayNativeRTPBudgetKeepsUsableFrameRateUnderSeriousThermalPressure() {
        let budget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 60,
            transportPath: .relay,
            thermalState: .serious,
            longEdge: 1920,
            lowLatencyMode: true,
            codec: .h264,
            nativeVideoTrackEnabled: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            isAppleSilicon: true
        )

        XCTAssertEqual(budget.frameRate, 30)
        XCTAssertEqual(budget.maxBufferedAmountBytes, 896_000)
        XCTAssertEqual(budget.reason, "relay-native-rtp")
    }

    func testRelayNativeRTPBudgetDoesNotCollapseToFallbackUnderCriticalThermalPressure() {
        let budget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 60,
            transportPath: .relay,
            thermalState: .critical,
            longEdge: 1920,
            lowLatencyMode: true,
            codec: .h264,
            nativeVideoTrackEnabled: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            isAppleSilicon: true
        )

        XCTAssertEqual(budget.frameRate, 15)
        XCTAssertEqual(budget.maxBufferedAmountBytes, 640_000)
        XCTAssertEqual(budget.reason, "relay-native-rtp")
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
        XCTAssertEqual(budget.maxBufferedAmountBytes, UInt64(WebRTCDegradedFallbackJPEGProfile.maxTransportFrameBytes))
    }

    func testNativeRelayFallbackBudgetUsesTransportFrameCeiling() {
        let budget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 60,
            transportPath: .relay,
            thermalState: .nominal,
            longEdge: 1920,
            lowLatencyMode: true,
            codec: .bgra,
            nativeVideoTrackEnabled: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            isAppleSilicon: true
        )

        XCTAssertEqual(budget.maxBufferedAmountBytes, UInt64(WebRTCDegradedFallbackJPEGProfile.maxTransportFrameBytes))
        XCTAssertGreaterThan(
            WebRTCDegradedFallbackJPEGProfile.maxTransportFrameBytes,
            WebRTCDegradedFallbackJPEGProfile.maxEncodedFrameBytes
        )
        XCTAssertEqual(budget.reason, "relay-degraded-emergency-jpeg")
    }
}
