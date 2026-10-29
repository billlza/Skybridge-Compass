// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Dispatch

extension ScreenCaptureKitStreamer {
    enum EncodedBitstreamFormat: Sendable {
        case native
        case annexB
    }

    struct CaptureContextSnapshot: Sendable, Equatable {
        let displayID: CGDirectDisplayID
        let displayPixelSize: CGSize
        let streamSize: CGSize
        let captureCursorInVideo: Bool
    }

    struct RawFrameDelivery: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
    }

    struct VideoEncodeRequest: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let presentationTimeStamp: CMTime
        let duration: CMTime
        let submittedAtUptimeNanoseconds: UInt64
        let sourceFrameGeneration: UInt64
        let sourceFrameRepeatCount: Int
        let sourceFrameAgeMsAtSubmission: Double
        let forcedKeyFrame: Bool
    }

    final class CompressionCallbackContext {
        private let lock = NSLock()
        weak var streamer: ScreenCaptureKitStreamer?
        private var isActive = true

        init(streamer: ScreenCaptureKitStreamer) {
            self.streamer = streamer
        }

        func deactivate() {
            lock.lock()
            isActive = false
            lock.unlock()
        }

        func activeStreamer() -> ScreenCaptureKitStreamer? {
            lock.lock()
            defer { lock.unlock() }
            guard isActive else { return nil }
            return streamer
        }
    }

    final class EncodeFrameTiming {
        let submittedAtUptimeNanoseconds: UInt64
        let actualSubmittedAtUptimeNanoseconds: UInt64
        let presentationTimeStamp: CMTime
        let duration: CMTime
        let sourceFrameGeneration: UInt64
        let sourceFrameRepeatCount: Int
        let sourceFrameAgeMsAtSubmission: Double
        let forcedKeyFrame: Bool

        init(
            submittedAtUptimeNanoseconds: UInt64,
            actualSubmittedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
            presentationTimeStamp: CMTime,
            duration: CMTime,
            sourceFrameGeneration: UInt64,
            sourceFrameRepeatCount: Int,
            sourceFrameAgeMsAtSubmission: Double,
            forcedKeyFrame: Bool
        ) {
            self.submittedAtUptimeNanoseconds = submittedAtUptimeNanoseconds
            self.actualSubmittedAtUptimeNanoseconds = actualSubmittedAtUptimeNanoseconds
            self.presentationTimeStamp = presentationTimeStamp
            self.duration = duration
            self.sourceFrameGeneration = sourceFrameGeneration
            self.sourceFrameRepeatCount = sourceFrameRepeatCount
            self.sourceFrameAgeMsAtSubmission = sourceFrameAgeMsAtSubmission
            self.forcedKeyFrame = forcedKeyFrame
        }
    }

    final class AudioConversionInputState: @unchecked Sendable {
        private let lock = NSLock()
        private var consumed = false

        func takeIfAvailable() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }
}
#endif
