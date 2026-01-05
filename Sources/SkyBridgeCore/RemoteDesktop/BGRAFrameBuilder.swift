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
    case bufferCreationFailed(OSStatus)
    case dataUnderrun
    case zeroCopyNotImplemented
}

public enum BGRAFrameBuilder {
    public static func buildPixelBuffer(from frame: BGRAFrame, mode: BGRAFrameBuildMode) throws -> CVPixelBuffer {
        switch mode {
        case .safeCopy:
            return try buildSafeCopy(frame: frame)
        case .zeroCopy:
            throw BGRAFrameBuilderError.zeroCopyNotImplemented
        }
    }
    private static func buildSafeCopy(frame: BGRAFrame) throws -> CVPixelBuffer {
        guard frame.width > 0, frame.height > 0 else { throw BGRAFrameBuilderError.invalidDimensions }
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferWidthKey: frame.width,
            kCVPixelBufferHeightKey: frame.height,
            kCVPixelBufferBytesPerRowAlignmentKey: frame.stride,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { throw BGRAFrameBuilderError.bufferCreationFailed(status) }
        let required = frame.stride * frame.height
        guard frame.data.count >= required else { throw BGRAFrameBuilderError.dataUnderrun }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let dst = base.bindMemory(to: UInt8.self, capacity: frame.stride * frame.height)
            frame.data.withUnsafeBytes { srcRaw in
                let src = srcRaw.bindMemory(to: UInt8.self)
                guard let srcBase = src.baseAddress else { return }
                let rowBytes = min(frame.stride, frame.width * 4)
                var sOff = 0
                var dOff = 0
                var row = 0
                while row < frame.height {
                    memcpy(dst.advanced(by: dOff), srcBase.advanced(by: sOff), rowBytes)
                    sOff += rowBytes
                    dOff += frame.stride
                    row += 1
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
