import Foundation
import XCTest
#if canImport(WebRTCAudioDeviceBridge)
import WebRTCAudioDeviceBridge
#endif

/// 系统音频采集设备是进程内单例，只有一个采样游标。
/// 早前的实现里，第二路会话激活自己的 owner 会直接顶掉在位的 owner 并重置游标，
/// 于是第一路观看者的音频静默中断，两端都没有任何错误可观测。
/// 独占必须是显式的：在位者保留，后来者被明确拒绝，由调用方决定如何降级。
final class SystemAudioCaptureOwnershipTests: XCTestCase {
#if canImport(WebRTCAudioDeviceBridge)
    func testASecondOwnerIsRefusedInsteadOfSilentlyDisplacingTheIncumbent() {
        let device = SBWebRTCSystemAudioDevice.shared()
        let firstSession = UUID()
        let secondSession = UUID()
        defer {
            device.retireRecordedAudioOwner(withToken: firstSession)
            device.retireRecordedAudioOwner(withToken: secondSession)
        }

        XCTAssertTrue(
            device.activateRecordedAudioOwner(withToken: firstSession),
            "设备空闲时第一路会话应当拿到采集权"
        )
        XCTAssertTrue(
            device.activateRecordedAudioOwner(withToken: firstSession),
            "同一 owner 重复激活是幂等的（编码器重启会走到这里）"
        )
        XCTAssertFalse(
            device.activateRecordedAudioOwner(withToken: secondSession),
            "在位者仍然存活时，第二路会话必须被拒绝，而不是把对方顶掉"
        )
        XCTAssertTrue(
            device.activateRecordedAudioOwner(withToken: firstSession),
            "被拒绝之后，在位者必须仍然持有采集权"
        )
    }

    func testOwnershipTransfersOnlyAfterTheIncumbentRetires() {
        let device = SBWebRTCSystemAudioDevice.shared()
        let firstSession = UUID()
        let secondSession = UUID()
        defer {
            device.retireRecordedAudioOwner(withToken: firstSession)
            device.retireRecordedAudioOwner(withToken: secondSession)
        }

        XCTAssertTrue(device.activateRecordedAudioOwner(withToken: firstSession))
        XCTAssertFalse(device.activateRecordedAudioOwner(withToken: secondSession))

        device.retireRecordedAudioOwner(withToken: secondSession)
        XCTAssertFalse(
            device.activateRecordedAudioOwner(withToken: secondSession),
            "退还一个自己并不持有的 token 不得释放在位者"
        )

        device.retireRecordedAudioOwner(withToken: firstSession)
        XCTAssertTrue(
            device.activateRecordedAudioOwner(withToken: secondSession),
            "在位者正常退出后，采集权才移交"
        )
    }

    func testCallerDisablesItsOutgoingTrackWhenCaptureIsDenied() throws {
        // 拒绝之后调用方必须真的不打开自己的系统音轨，否则会推一路空音频出去。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("nativeAudioCaptureGranted = SBWebRTCSystemAudioDevice.shared()"),
            "激活结果必须被接住"
        )
        XCTAssertTrue(
            source.contains("session.setOutgoingSystemAudioTrackEnabled(nativeAudioCaptureGranted)"),
            "外发音轨必须跟随实际拿到的采集权，而不是跟随意图"
        )
        XCTAssertTrue(
            source.contains("audioTxNativeCaptureDenied"),
            "被拒绝必须留下可观测的诊断，不能静默降级"
        )
        XCTAssertFalse(
            source.contains("session.setOutgoingSystemAudioTrackEnabled(shouldUseNativeAudioTrack)"),
            "旧的按意图开关的写法必须消失"
        )
    }
#endif
}
