import Foundation
import CoreGraphics
import ImageIO
import Vision
import SkyBridgeProtocolCore
@testable import SkyBridgeCore
import XCTest

final class LanDirectConnectionQRCodeTests: XCTestCase {
    private func fixture(name: String = "书房 Mac") throws -> LanDirectConnectionInfo {
        try .init(host: "192.168.1.60", port: 50978, deviceId: "9A770257-EE43-4D15-9031-D39B7A4AE045",
            protocolFingerprint: String(repeating: "ab", count: 32), deviceName: name, platform: "macos")
    }

    func testIndependentVisionReaderPreservesCompleteConnectionInformation() throws {
        let info = try fixture()
        let image = try LanDirectConnectionQRCode.image(for: info)
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observed = try XCTUnwrap(request.results)
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.payloadStringValue, try LanDirectConnectionInfoCodec.encode(info))
        if let output = ProcessInfo.processInfo.environment["SKYBRIDGE_LAN_QR_FIXTURE_OUTPUT"] {
            let url = URL(fileURLWithPath: output)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }

    func testLongUnicodeNameStillDecodesAtIntegerScale() throws {
        let info = try fixture(name: String(repeating: "音", count: 40))
        let image = try LanDirectConnectionQRCode.image(for: info, moduleScale: 3)
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        XCTAssertEqual(request.results?.count, 1)
        XCTAssertEqual(request.results?.first?.payloadStringValue, try LanDirectConnectionInfoCodec.encode(info))
    }

    func testQuietZoneAndPixelsAreExactBlackOrWhite() throws {
        let image = try LanDirectConnectionQRCode.image(for: fixture(), moduleScale: 3)
        XCTAssertEqual(image.bitsPerPixel, 8)
        XCTAssertEqual(image.width, image.height)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let border = 12
        var blackPixels = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let value = data[y * image.bytesPerRow + x]
                XCTAssertTrue(value == 0 || value == 255)
                if value == 0 { blackPixels += 1 }
                if x < border || y < border || x >= image.width - border || y >= image.height - border {
                    XCTAssertEqual(value, 255)
                }
            }
        }
        XCTAssertGreaterThan(blackPixels, 100)
    }

    func testRejectsUnboundedOrEmptyRenderScale() throws {
        XCTAssertThrowsError(try LanDirectConnectionQRCode.image(for: fixture(), moduleScale: 0))
        XCTAssertThrowsError(try LanDirectConnectionQRCode.image(for: fixture(), moduleScale: 13))
        XCTAssertThrowsError(try LanDirectConnectionQRCode.image(for: fixture(), moduleScale: Int.max))
    }
}
