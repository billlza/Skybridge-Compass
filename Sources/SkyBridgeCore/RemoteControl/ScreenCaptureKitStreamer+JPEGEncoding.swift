import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension ScreenCaptureKitStreamer {
    static func encodeDegradedFallbackJPEG(
        from cgImage: CGImage,
        profile: WebRTCDegradedFallbackJPEGProfile = .emergency
    ) -> (image: CGImage, data: Data, quality: CGFloat)? {
        let primary = scaledImageForDegradedJPEG(
            cgImage,
            maxLongEdge: profile.maxLongEdge
        ) ?? cgImage
        let candidateImages: [CGImage]
        if profile.maxLongEdge > WebRTCDegradedFallbackJPEGProfile.secondaryLongEdge,
           max(primary.width, primary.height) > WebRTCDegradedFallbackJPEGProfile.secondaryLongEdge,
           let secondary = scaledImageForDegradedJPEG(
                primary,
                maxLongEdge: WebRTCDegradedFallbackJPEGProfile.secondaryLongEdge
           ) {
            candidateImages = [primary, secondary]
        } else {
            candidateImages = [primary]
        }

        for candidate in candidateImages {
            for quality in profile.qualityLadder {
                guard let data = jpegData(from: candidate, quality: quality) else { continue }
                if data.count <= profile.maxEncodedFrameBytes {
                    return (image: candidate, data: data, quality: quality)
                }
            }
        }
        return nil
    }

    static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            dest,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func scaledImageForDegradedJPEG(_ image: CGImage, maxLongEdge: Int) -> CGImage? {
        func evenDimension(_ value: Int) -> Int {
            let clamped = max(2, value)
            return clamped.isMultiple(of: 2) ? clamped : clamped - 1
        }
        guard maxLongEdge > 0 else { return image }
        let sourceMaxEdge = max(image.width, image.height)
        guard sourceMaxEdge > maxLongEdge else { return image }
        let scale = CGFloat(maxLongEdge) / CGFloat(sourceMaxEdge)
        let width = evenDimension(Int((CGFloat(image.width) * scale).rounded()))
        let height = evenDimension(Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
