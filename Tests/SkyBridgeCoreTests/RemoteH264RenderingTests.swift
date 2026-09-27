import Combine
import CoreGraphics
import CoreVideo
import ImageIO
import Metal
import XCTest

@testable import SkyBridgeCore

final class RemoteH264RenderingTests: XCTestCase {
  // Small Baseline IDRs encoded from solid colors; no captured desktop/user data.
  private let black = Data(
    base64Encoded: "AAAAAQkQAAAAAWdCwB7d7ARAAAADAEAAAAMAo8WL4AAAAAFozg8sgAAAAWWIhAS8mKAAOKOA")!
  private let blue = Data(
    base64Encoded:
      "AAAAAQkQAAAAAWdCwArZC7ARAAADAAEAAAMAAg8SJkgAAAABaMuDyyAAAAFliIQFfEYoAA6gxwABsGjgACNDJ4A=")!
  private let portrait = Data(
    base64Encoded:
      "AAAAAQkQAAAAAWdCwArZFbARAAADAAEAAAMAAg8SJkgAAAABaMuDyyAAAAFliIQFfEYoAAuMxwABOhjgADYNXg==")!

  func testAllPresentationModesDisplaySingleH264FrameWithoutAnotherNetworkPacket() throws {
    let stable = StableRenderer()
    let fluid = FluidRenderer()
    let reference = ReferenceRenderer()
    defer {
      stable.teardown()
      fluid.teardown()
      reference.teardown()
    }
    let probes = [NativeFrameProbe(), NativeFrameProbe(), NativeFrameProbe()]
    stable.frameHandler = probes[0].receiveTexture
    stable.failureHandler = probes[0].fail
    fluid.frameHandler = probes[1].receiveTexture
    fluid.failureHandler = probes[1].fail
    reference.frameHandler = probes[2].receiveTexture
    reference.failureHandler = probes[2].fail
    stable.processFrame(data: blue, width: 32, height: 16, stride: 0, type: .h264)
    fluid.processFrame(data: blue, width: 32, height: 16, stride: 0, type: .h264)
    reference.processFrame(data: blue, width: 32, height: 16, stride: 0, type: .h264)
    for probe in probes { XCTAssertEqual(probe.next(), .frame(width: 32, height: 16)) }
  }

  func testBGRAAndJPEGPresentationStillProduceTextures() throws {
    let stable = StableRenderer()
    let fluid = FluidRenderer()
    let reference = ReferenceRenderer()
    defer {
      stable.teardown()
      fluid.teardown()
      reference.teardown()
    }
    let probes = [NativeFrameProbe(), NativeFrameProbe(), NativeFrameProbe()]
    stable.frameHandler = probes[0].receiveTexture
    fluid.frameHandler = probes[1].receiveTexture
    reference.frameHandler = probes[2].receiveTexture
    let bytes = Data(repeating: 0xFF, count: 4 * 4 * 4)
    stable.processFrame(data: bytes, width: 4, height: 4, stride: 16, type: .bgra)
    fluid.processFrame(data: bytes, width: 4, height: 4, stride: 16, type: .bgra)
    reference.processFrame(data: bytes, width: 4, height: 4, stride: 16, type: .bgra)
    XCTAssertTrue(fluid.pullAndRender())
    XCTAssertTrue(reference.pullAndRender())
    for probe in probes { XCTAssertEqual(probe.next(), .frame(width: 4, height: 4)) }
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 4, height: 4,
        bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let jpeg = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    stable.processStaticImage(data: jpeg as Data)
    XCTAssertEqual(probes[0].next(), .frame(width: 4, height: 4))
  }

  func testSeparateParameterSetsAndThreeByteStartCodesDecodeAtIDR() throws {
    let parsed = try H264AnnexBAccessUnit.parse(blue)
    let probe = NativeFrameProbe()
    let decoder = makeDecoder(probe)
    defer { decoder.teardown() }
    let sps = annexB([try XCTUnwrap(parsed.sequenceParameterSet)])
    let pps = annexB([try XCTUnwrap(parsed.pictureParameterSet)])
    let slices = annexB(parsed.nalUnits.filter { $0.first.map { $0 & 31 == 5 } == true })
    assertAwaitingParameters(try decoder.submit(data: slices).get())
    assertAwaitingParameters(try decoder.submit(data: sps).get())
    assertAwaitingParameters(try decoder.submit(data: pps).get())
    assertSubmitted(try decoder.submit(data: slices).get())
    XCTAssertEqual(probe.next(), .frame(width: 32, height: 16))
  }

  func testResolutionAndPortraitTransitionsUseActualParameterSetGeometry() throws {
    let probe = NativeFrameProbe()
    let decoder = makeDecoder(probe)
    defer { decoder.teardown() }
    for (data, width, height) in [
      (black, 16, 16), (blue, 32, 16), (portrait, 16, 32), (black, 16, 16),
    ] {
      assertSubmitted(try decoder.submit(data: data).get())
      XCTAssertEqual(probe.next(), .frame(width: width, height: height))
    }
  }

  func testMalformedFrameAndOversizedGeometryFailExplicitly() throws {
    let probe = NativeFrameProbe()
    let decoder = H264VideoDecoder(
      maximumWidth: 16, maximumHeight: 16,
      frameHandler: probe.receivePixels, failureHandler: probe.fail)
    defer { decoder.teardown() }
    guard case .failure(.invalidH264AccessUnit) = decoder.submit(data: Data([0, 0, 1, 0x80])) else {
      return XCTFail("Malformed NAL units must fail at the codec boundary")
    }
    guard
      case .failure(.unsupportedH264Dimensions(width: 32, height: 16)) = decoder.submit(data: blue)
    else {
      return XCTFail("SPS geometry must respect the consumer's dimensions")
    }
    assertSubmitted(try decoder.submit(data: black).get())
    XCTAssertEqual(probe.next(), .frame(width: 16, height: 16))
  }

  func testRetiredDecoderRejectsNewFramesAndFreshDecoderNeedsParameterSets() throws {
    let probe = NativeFrameProbe()
    let old = makeDecoder(probe)
    assertSubmitted(try old.submit(data: black).get())
    XCTAssertEqual(probe.next(), .frame(width: 16, height: 16))
    old.teardown()
    guard case .failure(.decoderClosed) = old.submit(data: blue) else {
      return XCTFail("Closed decoder accepted a frame")
    }
    let fresh = makeDecoder(probe)
    defer { fresh.teardown() }
    let slices = annexB(
      try H264AnnexBAccessUnit.parse(black).nalUnits.filter {
        $0.first.map { $0 & 31 == 5 } == true
      })
    assertAwaitingParameters(try fresh.submit(data: slices).get())
    assertSubmitted(try fresh.submit(data: blue).get())
    XCTAssertEqual(probe.next(), .frame(width: 32, height: 16))
  }

  func testSlowConsumerHasBoundedDecodeAndDeliveryQueue() throws {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let syncRequested = DispatchSemaphore(value: 0)
    let probe = NativeFrameProbe()
    let decoder = H264VideoDecoder(
      frameHandler: { frame in
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
        probe.receivePixels(frame)
      }, failureHandler: probe.fail, syncFrameHandler: { syncRequested.signal() })
    defer {
      release.signal()
      release.signal()
      release.signal()
      decoder.teardown()
    }
    assertSubmitted(try decoder.submit(data: black).get())
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    assertSubmitted(try decoder.submit(data: black).get())
    assertSubmitted(try decoder.submit(data: black).get())
    guard case .success(.droppedForBackpressure) = decoder.submit(data: black) else {
      return XCTFail("A stalled consumer must be bounded to three decoded frames")
    }
    guard case .success(.awaitingSyncFrame) = decoder.submit(data: Data([0, 0, 1, 0x41, 0x01]))
    else {
      return XCTFail("A dropped compressed frame requires a new sync frame")
    }
    XCTAssertEqual(
      syncRequested.wait(timeout: .now()), .timedOut,
      "Do not request another compressed frame while delivery is still full")
    for _ in 0..<3 { release.signal() }
    for _ in 0..<3 { XCTAssertEqual(probe.next(), .frame(width: 16, height: 16)) }
    XCTAssertEqual(
      syncRequested.wait(timeout: .now() + 5), .success,
      "A static source needs an explicit sync request when decoder capacity returns")
    XCTAssertEqual(
      syncRequested.wait(timeout: .now()), .timedOut,
      "One backpressure incident must produce exactly one sync request")
    assertSubmitted(try decoder.submit(data: black).get())
    release.signal()
    XCTAssertEqual(probe.next(), .frame(width: 16, height: 16))
    decoder.teardown()
    XCTAssertEqual(
      syncRequested.wait(timeout: .now()), .timedOut,
      "Recovery must clear its request and teardown must not emit a later request")
  }

  @MainActor
  func testRetiredStreamCannotPublishThroughAReusedDeliveryGate() async throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: 2, height: 2, mipmapped: false)
    let oldTexture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let newTexture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let feed = RemoteTextureFeed()
    let delivered = expectation(description: "current stream frame")
    let gate = LatestTextureDeliveryGate(feed: feed)
    let observation = feed.$frame.dropFirst().compactMap { $0 }.sink { _ in delivered.fulfill() }
    defer { observation.cancel() }
    let oldGeneration = gate.currentGeneration
    gate.submit(texture: oldTexture, expectedGeneration: oldGeneration)
    gate.clear()
    gate.submit(texture: newTexture, expectedGeneration: gate.currentGeneration)
    // A late old decoder callback must not replace the current stream's pending slot.
    gate.submit(texture: oldTexture, expectedGeneration: oldGeneration)
    await fulfillment(of: [delivered], timeout: 5)
    XCTAssertTrue(feed.texture === newTexture)
  }

  private func makeDecoder(_ probe: NativeFrameProbe) -> H264VideoDecoder {
    H264VideoDecoder(frameHandler: probe.receivePixels, failureHandler: probe.fail)
  }
  private func annexB(_ units: [Data]) -> Data {
    units.reduce(into: Data()) {
      $0.append(contentsOf: [0, 0, 1])
      $0.append($1)
    }
  }
  private func assertSubmitted(
    _ value: RemoteH264FrameSubmissionResult, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .submitted = value else {
      return XCTFail("Expected a real decoder submission", file: file, line: line)
    }
  }
  private func assertAwaitingParameters(
    _ value: RemoteH264FrameSubmissionResult, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .awaitingParameterSets = value else {
      return XCTFail("Cannot decode without fresh SPS/PPS", file: file, line: line)
    }
  }
}

private final class NativeFrameProbe: @unchecked Sendable {
  enum Outcome: Equatable {
    case frame(width: Int, height: Int)
    case failure(String)
    case timeout
  }
  private let lock = NSLock()
  private let available = DispatchSemaphore(value: 0)
  private var outcomes: [Outcome] = []
  func receiveTexture(_ texture: MTLTexture, _ backing: AnyObject?) {
    append(.frame(width: texture.width, height: texture.height))
  }
  func receivePixels(_ frame: DecodedFrameRingBuffer.BufferedFrame) {
    append(
      .frame(
        width: CVPixelBufferGetWidth(frame.pixelBuffer),
        height: CVPixelBufferGetHeight(frame.pixelBuffer)))
  }
  func fail(_ error: RemoteFrameRenderError) { append(.failure(error.localizedDescription)) }
  private func append(_ outcome: Outcome) {
    lock.lock()
    outcomes.append(outcome)
    lock.unlock()
    available.signal()
  }
  func next() -> Outcome {
    guard available.wait(timeout: .now() + 5) == .success else { return .timeout }
    lock.lock()
    defer { lock.unlock() }
    return outcomes.removeFirst()
  }
}
