import Combine
import XCTest

@testable import SkyBridgeCore

@MainActor
final class RemoteControlManagerRenderingTests: XCTestCase {
  func testAuthenticatedH264ProducesTextureAcrossStreamRecreationAndModes() async throws {
    let manager = RemoteControlManager(controlledHostStreamTier: .background)
    manager.testingInstallViewerPeer(deviceId: "host", keys: keys(role: .initiator))
    defer { manager.stopControlling(deviceId: "host") }
    let picture = try XCTUnwrap(
      Data(
        base64Encoded:
          "AAAAAQkQAAAAAWdCwArZC7ARAAADAAEAAAMAAg8SJkgAAAABaMuDyyAAAAFliIQFfEYoAA6gxwABsGjgACNDJ4A="
      ))
    for (index, mode) in [RenderingMode.stable, .fluid, .reference, .stable].enumerated() {
      manager.testingPrepareViewerStream(mode: mode)
      XCTAssertNil(
        manager.textureFeed.frame, "A new stream must immediately retire the previous frame")
      let received = expectation(description: "decoded current stream \(index)")
      let observation = manager.textureFeed.$frame.dropFirst().compactMap { $0 }.sink { frame in
        XCTAssertEqual(frame.texture.width, 32)
        XCTAssertEqual(frame.texture.height, 16)
        received.fulfill()
      }
      let payload = RemoteDesktopScreenFrameWire.encode(
        width: 32, height: 16, imageData: picture,
        timestamp: Date().timeIntervalSince1970, format: "h264", isSyncFrame: true,
        sequenceNumber: UInt64(index + 1))
      let encrypted = try RemoteControlSecureEnvelope.seal(
        payload, keys: keys(role: .responder),
        packetType: .screen, counter: UInt64(index + 1))
      try await manager.testingReceiveViewerFrame(encrypted, from: "host")
      await fulfillment(of: [received], timeout: 5)
      observation.cancel()
      XCTAssertNil(manager.controllingSessionError)
      XCTAssertNotNil(manager.textureFeed.frame)
    }
  }

  private func keys(role: HandshakeRole) -> SessionKeys {
    SessionKeys(
      sendKey: Data(repeating: role == .initiator ? 0x11 : 0x22, count: 32),
      receiveKey: Data(repeating: role == .initiator ? 0x22 : 0x11, count: 32),
      negotiatedSuite: .xwingMLDSA, role: role, transcriptHash: Data(repeating: 0x31, count: 32))
  }
}
