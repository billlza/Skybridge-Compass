import Foundation
import CoreVideo
// .safeCopy：Data → PixelBuffer 自有内存，生命周期独立，适合所有平台
// .zeroCopy：仅在满足（Apple Silicon + 指定 OS 版本 + 驱动行为验证通过）条件时启用；未实现阶段 fail fast

public struct BGRAFrame {
    public let data: Data
    public let width: Int
    public let height: Int
    public let stride: Int
    public init(data: Data, width: Int, height: Int, stride: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.stride = stride
    }
}

public enum BGRAFrameBuildMode {
    case safeCopy
    case zeroCopy
}

public enum BGRAFrameBuilderError: Error {
    case invalidDimensions
    case invalidStride
    case frameTooLarge(limit: Int)
    case bufferCreationFailed(OSStatus)
    case dataUnderrun
    case zeroCopyNotImplemented
}

public enum BGRAFrameBuilder {
    public static let maximumWidth = 7_680
    public static let maximumHeight = 4_320
    public static let maximumFrameBytes = 160 * 1_024 * 1_024

    public static func buildPixelBuffer(from frame: BGRAFrame, mode: BGRAFrameBuildMode) throws -> CVPixelBuffer {
        switch mode {
        case .safeCopy:
            return try buildSafeCopy(frame: frame)
        case .zeroCopy:
            throw BGRAFrameBuilderError.zeroCopyNotImplemented
        }
    }
    private static func buildSafeCopy(frame: BGRAFrame) throws -> CVPixelBuffer {
        guard frame.width > 0,
              frame.height > 0,
              frame.width <= maximumWidth,
              frame.height <= maximumHeight else {
            throw BGRAFrameBuilderError.invalidDimensions
        }

        let (visibleRowBytes, rowBytesOverflow) = frame.width.multipliedReportingOverflow(by: 4)
        guard !rowBytesOverflow else { throw BGRAFrameBuilderError.invalidDimensions }

        // A stride of 0 means "tightly packed". Defaulting to width * 4 (BGRA = 4
        // bytes/px) avoids the previous bug where stride 0 made `required` and the
        // per-row copy length both 0, producing a solid-black frame.
        let srcStride = frame.stride > 0 ? frame.stride : visibleRowBytes
        guard srcStride >= visibleRowBytes else { throw BGRAFrameBuilderError.invalidStride }
        let (required, requiredOverflow) = srcStride.multipliedReportingOverflow(by: frame.height)
        guard !requiredOverflow,
              required <= maximumFrameBytes,
              frame.data.count <= maximumFrameBytes else {
            throw BGRAFrameBuilderError.frameTooLarge(limit: maximumFrameBytes)
        }
        guard frame.data.count >= required else { throw BGRAFrameBuilderError.dataUnderrun }

        var pixelBuffer: CVPixelBuffer?
        // Let CoreVideo pick its own (aligned) bytesPerRow; we copy row-by-row using
        // the created buffer's actual stride rather than assuming the source stride,
        // which fixes a latent corruption bug when the two differ.
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferWidthKey: frame.width,
            kCVPixelBufferHeightKey: frame.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { throw BGRAFrameBuilderError.bufferCreationFailed(status) }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let dstStride = CVPixelBufferGetBytesPerRow(buffer)
        let (destinationCapacity, destinationOverflow) = dstStride.multipliedReportingOverflow(by: frame.height)
        guard !destinationOverflow, destinationCapacity <= maximumFrameBytes else {
            throw BGRAFrameBuilderError.frameTooLarge(limit: maximumFrameBytes)
        }
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let dst = base.bindMemory(to: UInt8.self, capacity: destinationCapacity)
            frame.data.withUnsafeBytes { srcRaw in
                guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                // Copy only the visible bytes per row, bounded by both strides.
                let rowBytes = min(srcStride, dstStride, visibleRowBytes)
                var sOff = 0
                var dOff = 0
                var row = 0
                while row < frame.height {
                    memcpy(dst.advanced(by: dOff), srcBase.advanced(by: sOff), rowBytes)
                    sOff += srcStride
                    dOff += dstStride
                    row += 1
                }
            }
        }
        return buffer
    }
}
