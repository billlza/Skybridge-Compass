import Combine
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SkyBridgeProtocolCore

@available(iOS 17.0, *)
struct CameraFramePresentationContext: Equatable, Sendable {
    let sessionGeneration: UInt64
    let sessionID: String
    let width: Int
    let height: Int
}

@available(iOS 17.0, *)
struct RemoteDesktopFramePresentationContext: Equatable, Sendable {
    let sequenceNumber: UInt64
    let streamTransaction: RemoteDesktopStreamConfigurationTransaction
    let streamEpoch: UInt64
}

@available(iOS 17.0, *)
final class DecodedImageFrame: @unchecked Sendable {
    let image: CGImage

    init(image: CGImage) {
        self.image = image
    }
}

@available(iOS 17.0, *)
final class DecodedPixelBufferFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    let presentationTimeStamp: CMTime
    let cameraPresentationContext: CameraFramePresentationContext?
    let framePresentationContext: RemoteDesktopFramePresentationContext?

    init(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        presentationTimeStamp: CMTime,
        cameraPresentationContext: CameraFramePresentationContext? = nil,
        framePresentationContext: RemoteDesktopFramePresentationContext? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.width = width
        self.height = height
        self.presentationTimeStamp = presentationTimeStamp
        self.cameraPresentationContext = cameraPresentationContext
        self.framePresentationContext = framePresentationContext
    }
}

@available(iOS 17.0, *)
final class DisplaySampleBufferFrame: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let width: Int
    let height: Int
    let presentationTimeStamp: CMTime
    let cameraPresentationContext: CameraFramePresentationContext?
    let framePresentationContext: RemoteDesktopFramePresentationContext?

    init(
        sampleBuffer: CMSampleBuffer,
        width: Int,
        height: Int,
        presentationTimeStamp: CMTime,
        cameraPresentationContext: CameraFramePresentationContext? = nil,
        framePresentationContext: RemoteDesktopFramePresentationContext? = nil
    ) {
        self.sampleBuffer = sampleBuffer
        self.width = width
        self.height = height
        self.presentationTimeStamp = presentationTimeStamp
        self.cameraPresentationContext = cameraPresentationContext
        self.framePresentationContext = framePresentationContext
    }
}

@available(iOS 17.0, *)
enum DecodeOutput: Sendable {
    case image(DecodedImageFrame)
    case pixelBuffer(DecodedPixelBufferFrame)
    case sampleBuffer(DisplaySampleBufferFrame)
}

@available(iOS 17.0, *)
@MainActor
final class RemoteVideoFrameFeed: ObservableObject {
    private static let maxPendingFrames = 3
    @Published private(set) var frameVersion: UInt64 = 0

    private(set) var pendingFrames: [DisplaySampleBufferFrame] = []
    private(set) var flushVersion: UInt64 = 0
    private(set) var hasDisplayedFrame = false
    private(set) var removeDisplayedImageOnFlush = true

    var hasFrame: Bool {
        hasDisplayedFrame || !pendingFrames.isEmpty
    }

    func enqueue(frame: DisplaySampleBufferFrame) {
        pendingFrames.append(frame)
        if pendingFrames.count > Self.maxPendingFrames {
            pendingFrames.removeFirst(pendingFrames.count - Self.maxPendingFrames)
        }
        frameVersion &+= 1
    }

    func markDisplayedFrame() {
        hasDisplayedFrame = true
    }

    func takePendingFrames() -> [DisplaySampleBufferFrame] {
        let frames = pendingFrames
        pendingFrames.removeAll(keepingCapacity: true)
        return frames
    }

    func flush(removeDisplayedImage: Bool = true) {
        pendingFrames.removeAll(keepingCapacity: true)
        removeDisplayedImageOnFlush = removeDisplayedImage
        if removeDisplayedImage {
            hasDisplayedFrame = false
        }
        flushVersion &+= 1
        frameVersion &+= 1
    }
}

@available(iOS 17.0, *)
@MainActor
final class RemoteMetalVideoFrameFeed: ObservableObject {
    enum ConsumerResult: Sendable {
        case accepted
        case staleConsumer
        case rejected(reason: String)
    }

    struct DeliveryResult: Sendable {
        let consumerCount: Int
        let staleConsumerCount: Int
        let acceptedConsumerCount: Int
        let rejectedConsumerCount: Int
        let rejectionReasons: [String]
        let frameVersion: UInt64

        var acceptedByRenderer: Bool {
            acceptedConsumerCount > 0
        }

        var activeConsumerCount: Int {
            max(0, consumerCount - staleConsumerCount)
        }

        var hasQueueBackpressureRejection: Bool {
            rejectionReasons.contains { $0.contains("queue-full") }
        }

        var rejectionSummary: String {
            let summary = rejectionReasons.prefix(3).joined(separator: "|")
            return summary.isEmpty ? "unspecified" : summary
        }
    }

    @Published private(set) var surfaceInvalidationVersion: UInt64 = 0
    private(set) var frameVersion: UInt64 = 0

    private(set) var latestFrame: DecodedPixelBufferFrame?
    private(set) var flushVersion: UInt64 = 0
    private(set) var hasDisplayedFrame = false
    private(set) var removeDisplayedImageOnFlush = true
    private var frameConsumers: [UUID: (DecodedPixelBufferFrame, UInt64) -> ConsumerResult] = [:]

    var hasFrame: Bool {
        hasDisplayedFrame || latestFrame != nil
    }

    var activeConsumerCount: Int {
        frameConsumers.count
    }

    @discardableResult
    func enqueue(frame: DecodedPixelBufferFrame) -> DeliveryResult {
        let shouldPublishSurfaceAvailability = latestFrame == nil && !hasDisplayedFrame
        if shouldPublishSurfaceAvailability {
            surfaceInvalidationVersion &+= 1
        }
        latestFrame = frame
        frameVersion &+= 1
        let version = frameVersion
        let consumerCount = frameConsumers.count
        var acceptedConsumerCount = 0
        var staleConsumerIDs: [UUID] = []
        var rejectedConsumerCount = 0
        var rejectionReasons: [String] = []
        for (id, consumer) in frameConsumers {
            switch consumer(frame, version) {
            case .accepted:
                acceptedConsumerCount += 1
            case .staleConsumer:
                staleConsumerIDs.append(id)
            case .rejected(let reason):
                rejectedConsumerCount += 1
                rejectionReasons.append(reason)
            }
        }
        for id in staleConsumerIDs {
            frameConsumers.removeValue(forKey: id)
        }
        return DeliveryResult(
            consumerCount: consumerCount,
            staleConsumerCount: staleConsumerIDs.count,
            acceptedConsumerCount: acceptedConsumerCount,
            rejectedConsumerCount: rejectedConsumerCount,
            rejectionReasons: rejectionReasons,
            frameVersion: version
        )
    }

    func addFrameConsumer(_ consumer: @escaping (DecodedPixelBufferFrame, UInt64) -> ConsumerResult) -> UUID {
        let id = UUID()
        frameConsumers[id] = consumer
        return id
    }

    func removeFrameConsumer(_ id: UUID?) {
        guard let id else { return }
        frameConsumers.removeValue(forKey: id)
    }

    func markDisplayedFrame() {
        hasDisplayedFrame = true
    }

    func takeLatestFrame() -> DecodedPixelBufferFrame? {
        // 不要清空 latestFrame - 保留它用于重复显示
        // MTKView 的 draw(in:) 可能以 60fps 调用，但帧到达速度可能更低
        // 如果清空，会导致 draw(in:) 取不到帧而显示空白
        return latestFrame
    }

    func flush(removeDisplayedImage: Bool = true) {
        surfaceInvalidationVersion &+= 1
        latestFrame = nil
        removeDisplayedImageOnFlush = removeDisplayedImage
        if removeDisplayedImage {
            hasDisplayedFrame = false
        }
        flushVersion &+= 1
        frameVersion &+= 1
    }
}
