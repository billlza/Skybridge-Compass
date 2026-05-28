import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox
import XCTest
@testable import SkyBridgeCore

final class WebRTCCGDisplayVideoEncoderTests: XCTestCase {
    func testPixelBufferRendererKeepsDesktopTopRowAtTop() throws {
        let image = try makeTwoRowTestImage()
        guard let pixelBuffer = WebRTCCGDisplayPixelBufferRenderer.makePixelBuffer(from: image, width: 2, height: 2) else {
            XCTFail("Expected pixel buffer")
            return
        }

        var renderedImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &renderedImage)
        XCTAssertEqual(status, noErr)
        guard let renderedImage else {
            XCTFail("Expected rendered CGImage")
            return
        }

        let topLeft = try sampleRGBA(renderedImage, x: 0, y: 0)
        let bottomLeft = try sampleRGBA(renderedImage, x: 0, y: 1)

        XCTAssertEqual(topLeft, [255, 0, 0, 255], "Top row should remain red")
        XCTAssertEqual(bottomLeft, [0, 0, 255, 255], "Bottom row should remain blue")
    }

    func testHEVCSessionCreationFailureDoesNotFallbackToH264() throws {
        let source = try webRTCCGDisplayVideoEncoderSource()
        let failureBody = try sourceSlice(
            from: "if status != noErr || session == nil {",
            to: "compressionSession = session",
            in: source
        )

        XCTAssertTrue(failureBody.contains("refusing automatic H.264 fallback"))
        XCTAssertFalse(failureBody.contains("codecType = kCMVideoCodecType_H264"))
        XCTAssertFalse(
            failureBody.contains("setupCompressionSession(width: width, height: height, codec: kCMVideoCodecType_H264)"),
            "HEVC encoder setup failures must fail fast instead of silently changing the negotiated codec."
        )
    }

    private func makeTwoRowTestImage() throws -> CGImage {
        let width = 2
        let height = 2
        let bytesPerRow = width * 4
        let pixels: [UInt8] = [
            255, 0, 0, 255,   255, 0, 0, 255,
            0, 0, 255, 255,   0, 0, 255, 255
        ]
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw NSError(domain: "WebRTCCGDisplayVideoEncoderTests", code: 1)
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw NSError(domain: "WebRTCCGDisplayVideoEncoderTests", code: 2)
        }
        return image
    }

    private func sampleRGBA(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "WebRTCCGDisplayVideoEncoderTests", code: 3)
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = (y * bytesPerRow) + (x * 4)
        return Array(pixels[offset..<(offset + 4)])
    }

    private func webRTCCGDisplayVideoEncoderSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("SkyBridgeCore")
            .appendingPathComponent("RemoteConnection")
            .appendingPathComponent("WebRTC")
            .appendingPathComponent("WebRTCCGDisplayVideoEncoder.swift")
        return try String(contentsOf: path)
    }

    private func sourceSlice(from startMarker: String, to endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound else {
            XCTFail("source markers not found: \(startMarker) -> \(endMarker)")
            return source
        }
        return String(source[start..<end])
    }
}
