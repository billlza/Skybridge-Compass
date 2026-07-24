import Foundation
import XCTest
@testable import SkyBridgeCore

final class CameraH264RenderIntegrationTests: XCTestCase {
    func testValidH264CameraAccessUnitProducesMetalTexture() throws {
        // Generated as a 16x16 black Baseline IDR with repeat-headers/AUD enabled and SEI
        // removed. Keeping a tiny deterministic bitstream exercises the real
        // VideoToolbox -> CVPixelBuffer -> Metal texture path without a fake decoder.
        let accessUnit = try XCTUnwrap(
            Data(
                base64Encoded: "AAAAAQkQAAAAAWdCwB7d7ARAAAADAEAAAAMAo8WL4AAAAAFozg8sgAAAAWWIhAS8mKAAOKOA"
            )
        )
        let renderer = RemoteFrameRenderer()
        let probe = CameraRenderProbe()
        renderer.frameHandler = { texture, _ in
            probe.complete(.texture(width: texture.width, height: texture.height))
        }
        renderer.failureHandler = { error in
            probe.complete(.failure(error.localizedDescription))
        }
        defer { renderer.teardown() }

        let submission = try renderer.processH264AnnexBAccessUnit(data: accessUnit)
        guard case .submitted = submission else {
            return XCTFail("A complete SPS/PPS/IDR access unit must be submitted to VideoToolbox")
        }

        XCTAssertEqual(
            probe.wait(timeout: .now() + 5),
            .texture(width: 16, height: 16)
        )
    }
}

private final class CameraRenderProbe: @unchecked Sendable {
    enum Outcome: Equatable {
        case texture(width: Int, height: Int)
        case failure(String)
        case timedOut
    }

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outcome: Outcome?

    func complete(_ value: Outcome) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = value
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> Outcome {
        guard semaphore.wait(timeout: timeout) == .success else { return .timedOut }
        lock.lock()
        defer { lock.unlock() }
        return outcome ?? .timedOut
    }
}
