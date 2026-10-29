#if os(macOS)
import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import SkyBridgeProtocolCore

public enum LanDirectConnectionQRCodeError: Error {
    case invalidScale, renderingUnavailable
}

/// A local visual representation of the complete public route. No trust or network effects.
public enum LanDirectConnectionQRCode {
    public static func image(for info: LanDirectConnectionInfo, moduleScale: Int = 6) throws -> CGImage {
        guard (1...12).contains(moduleScale) else { throw LanDirectConnectionQRCodeError.invalidScale }
        let text = try LanDirectConnectionInfoCodec.encode(info)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width == output.extent.height,
              output.extent.width > 0, output.extent.width <= 256,
              output.extent.width.rounded(.down) == output.extent.width else {
            throw LanDirectConnectionQRCodeError.renderingUnavailable
        }
        let renderer = CIContext(options: [.useSoftwareRenderer: true])
        guard let modules = renderer.createCGImage(output, from: output.extent) else {
            throw LanDirectConnectionQRCodeError.renderingUnavailable
        }
        // Integer scaling and an explicit four-module quiet zone; no logo or smoothing.
        let border = 4 * moduleScale
        let contentSide = modules.width * moduleScale
        let side = contentSide + border * 2
        guard let bitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw LanDirectConnectionQRCodeError.renderingUnavailable
        }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: side, height: side))
        bitmap.interpolationQuality = .none
        bitmap.draw(modules, in: CGRect(x: border, y: border, width: contentSide, height: contentSide))
        guard let result = bitmap.makeImage() else { throw LanDirectConnectionQRCodeError.renderingUnavailable }
        return result
    }
}
#endif
