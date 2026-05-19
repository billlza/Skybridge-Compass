import XCTest
@testable import SkyBridgeCore

final class WebRTCRemoteDesktopVideoFormatPolicyTests: XCTestCase {
    func testPreferredJPEGForcesRemoteFormatsToJPEGOnly() {
        let config = streamConfiguration(
            preferredCodec: "jpeg",
            supportedVideoFormats: ["h264", "hevc"]
        )

        XCTAssertEqual(
            WebRTCRemoteDesktopVideoFormatPolicy.effectiveRemoteVideoFormats(
                advertisedFormats: ["h264", "hevc"],
                streamConfiguration: config
            ),
            ["jpeg"]
        )
    }

    func testRemoteFormatsMergeAdvertisedSupportedAndPreferredCodecsCaseInsensitively() {
        let config = streamConfiguration(
            preferredCodec: "HEVC",
            supportedVideoFormats: ["H264", "JPEG"]
        )

        XCTAssertEqual(
            WebRTCRemoteDesktopVideoFormatPolicy.effectiveRemoteVideoFormats(
                advertisedFormats: ["JPEG"],
                streamConfiguration: config
            ),
            ["jpeg", "h264", "hevc"]
        )
    }

    func testNativeCaptureFormatsExcludeJPEGAndAllowPreferredNativeCodecs() {
        let config = streamConfiguration(
            preferredCodec: "hevc",
            supportedVideoFormats: ["jpeg", "h264"]
        )

        XCTAssertEqual(
            WebRTCRemoteDesktopVideoFormatPolicy.effectiveNativeCaptureVideoFormats(
                localSupportedFormats: ["h264"],
                streamConfiguration: config
            ),
            ["h264", "hevc"]
        )
    }

    func testSupportedRemoteVideoFormatsPreserveExistingHEVCOrdering() {
        XCTAssertEqual(
            WebRTCRemoteDesktopVideoFormatPolicy.supportedRemoteVideoFormats(hevcHardwareDecodeSupported: true),
            ["hevc", "jpeg", "h264"]
        )
        XCTAssertEqual(
            WebRTCRemoteDesktopVideoFormatPolicy.supportedRemoteVideoFormats(hevcHardwareDecodeSupported: false),
            ["jpeg", "h264"]
        )
    }

    private func streamConfiguration(
        preferredCodec: String?,
        supportedVideoFormats: [String]
    ) -> RemoteDesktopStreamConfiguration {
        RemoteDesktopStreamConfiguration(
            preferredCodec: preferredCodec,
            supportedVideoFormats: supportedVideoFormats,
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false
        )
    }
}
