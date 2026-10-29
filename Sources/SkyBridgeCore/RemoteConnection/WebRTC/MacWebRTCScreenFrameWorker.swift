#if os(macOS)
import CoreGraphics
import Foundation

/// Serial, bounded worker for the macOS WebRTC screen-frame preparation pipeline.
///
/// The worker owns exactly one in-flight request and one replaceable pending
/// request. Producers therefore never enqueue an unbounded number of screen
/// frames when capture, damage analysis, JPEG/wire encoding, or AEAD falls behind.
final class MacWebRTCScreenFrameWorker: @unchecked Sendable {
    struct Request: Sendable {
        let id: UInt64
        let sequenceNumber: UInt64
        let sourceFrame: ScreenDataWire?
        let damageTrackingEnabled: Bool
        let resetDamageTracker: Bool
        let degradedJPEGProfile: WebRTCDegradedFallbackJPEGProfile?
        let jpegQuality: CGFloat
        let keys: SessionKeys
        let secureCounter: UInt64
        let secureStateFingerprint: String
    }

    struct PreparedFrame: Sendable {
        let requestID: UInt64
        let frame: ScreenDataWire
        let encryptedPayload: Data
        let damageReport: RemoteDesktopDamageReport?
        let captureMilliseconds: Int
        let jpegEncodeMilliseconds: Int
        let jpegQuality: CGFloat
        let usedDegradedJPEGProfile: Bool
        let isIndependentFrame: Bool
        let secureStateFingerprint: String
    }

    struct Snapshot: Sendable, Equatable {
        let submitted: UInt64
        let processed: UInt64
        let droppedPending: UInt64
        let replacedReady: UInt64
        let hasInFlight: Bool
        let hasPending: Bool
        let hasReadyResult: Bool
        let isStopped: Bool
    }

    enum ProcessingResult: Sendable {
        case prepared(PreparedFrame)
        case noDamage(captureMilliseconds: Int)
        case captureUnavailable
        case jpegEncodingFailed
        case encryptionFailed(String)
    }

    typealias Processor = @Sendable (Request) -> ProcessingResult

    private let queue = DispatchQueue(
        label: "com.skybridge.connection.webrtc.cg-jpeg-frame-worker",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let lock = NSLock()
    private let processor: Processor

    private var pendingRequest: Request?
    private var readyResult: ProcessingResult?
    private var drainScheduled = false
    private var inFlight = false
    private var stopped = false
    private var terminalEncryptionFailure = false
    private var submitted: UInt64 = 0
    private var processed: UInt64 = 0
    private var droppedPending: UInt64 = 0
    private var replacedReady: UInt64 = 0

    convenience init() {
        let damageTracker = CoarseDisplayDamageTracker()
        self.init { request in
            Self.process(request, damageTracker: damageTracker)
        }
    }

    init(processor: @escaping Processor) {
        self.processor = processor
    }

    /// Replaces an older pending request. An already-running request is allowed
    /// to finish, so total retained work is bounded to one in-flight plus one pending.
    func submit(_ request: Request) {
        let shouldSchedule: Bool
        lock.lock()
        guard !stopped, !terminalEncryptionFailure else {
            lock.unlock()
            return
        }
        submitted &+= 1
        if let pendingRequest,
           Self.isIndependentFrameHint(pendingRequest),
           !Self.isIndependentFrameHint(request) {
            // Preserve an unsent recovery frame over a newer predictive frame.
            droppedPending &+= 1
            lock.unlock()
            return
        }
        if pendingRequest != nil {
            droppedPending &+= 1
        }
        pendingRequest = request
        shouldSchedule = !drainScheduled
        if shouldSchedule {
            drainScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        queue.async { [weak self] in
            self?.drain()
        }
    }

    func takeLatestResult() -> ProcessingResult? {
        lock.lock()
        defer { lock.unlock() }
        defer { readyResult = nil }
        return readyResult
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            submitted: submitted,
            processed: processed,
            droppedPending: droppedPending,
            replacedReady: replacedReady,
            hasInFlight: inFlight,
            hasPending: pendingRequest != nil,
            hasReadyResult: readyResult != nil,
            isStopped: stopped
        )
    }

    func stop() {
        lock.lock()
        stopped = true
        if pendingRequest != nil {
            droppedPending &+= 1
        }
        pendingRequest = nil
        readyResult = nil
        lock.unlock()
    }

    private func drain() {
        while true {
            let request: Request
            lock.lock()
            guard !stopped, !terminalEncryptionFailure, let next = pendingRequest else {
                pendingRequest = nil
                inFlight = false
                drainScheduled = false
                lock.unlock()
                return
            }
            pendingRequest = nil
            inFlight = true
            request = next
            lock.unlock()

            let result = processor(request)

            lock.lock()
            processed &+= 1
            inFlight = false
            guard !stopped else {
                lock.unlock()
                continue
            }
            storeReadyResult(result)
            lock.unlock()
        }
    }

    private func storeReadyResult(_ result: ProcessingResult) {
        if case .encryptionFailed = result {
            terminalEncryptionFailure = true
            pendingRequest = nil
        }

        // A no-damage observation is relative to the previously processed image.
        // It must not erase an unconsumed changed frame, because that would leave
        // the viewer permanently behind while the desktop remains unchanged.
        if case .noDamage = result,
           case .prepared = readyResult {
            return
        }
        if case .prepared(let ready) = readyResult,
           ready.isIndependentFrame,
           case .prepared(let replacement) = result,
           !replacement.isIndependentFrame {
            replacedReady &+= 1
            return
        }
        if readyResult != nil {
            replacedReady &+= 1
        }
        readyResult = result
    }

    private static func isIndependentFrameHint(_ request: Request) -> Bool {
        guard let sourceFrame = request.sourceFrame else {
            return true
        }
        return sourceFrame.isSyncFrame == true
    }

    private static func process(
        _ request: Request,
        damageTracker: CoarseDisplayDamageTracker
    ) -> ProcessingResult {
        if let sourceFrame = request.sourceFrame {
            return prepare(
                frame: sourceFrame,
                damageReport: nil,
                captureMilliseconds: 0,
                jpegEncodeMilliseconds: 0,
                jpegQuality: request.jpegQuality,
                usedDegradedJPEGProfile: false,
                request: request
            )
        }

        if request.resetDamageTracker {
            damageTracker.reset()
        }

        let captureStartedAt = Date()
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            return .captureUnavailable
        }
        let captureMilliseconds = Int(
            (Date().timeIntervalSince(captureStartedAt) * 1_000).rounded()
        )

        let damageReport: RemoteDesktopDamageReport?
        if request.damageTrackingEnabled {
            guard let report = damageTracker.analyze(image: image) else {
                return .noDamage(captureMilliseconds: captureMilliseconds)
            }
            damageReport = report
        } else {
            damageReport = nil
        }

        let jpegStartedAt = Date()
        let jpegResult: (image: CGImage, data: Data, quality: CGFloat)?
        if let profile = request.degradedJPEGProfile {
            jpegResult = ScreenCaptureKitStreamer.encodeDegradedFallbackJPEG(
                from: image,
                profile: profile
            )
        } else if let data = ScreenCaptureKitStreamer.jpegData(
            from: image,
            quality: request.jpegQuality
        ) {
            jpegResult = (image: image, data: data, quality: request.jpegQuality)
        } else {
            jpegResult = nil
        }
        guard let jpegResult else {
            return .jpegEncodingFailed
        }
        let jpegEncodeMilliseconds = Int(
            (Date().timeIntervalSince(jpegStartedAt) * 1_000).rounded()
        )

        let frame = ScreenDataWire(
            width: jpegResult.image.width,
            height: jpegResult.image.height,
            imageData: jpegResult.data,
            timestamp: Date().timeIntervalSince1970,
            format: "jpeg",
            isSyncFrame: true,
            sequenceNumber: request.sequenceNumber
        )
        return prepare(
            frame: frame,
            damageReport: damageReport,
            captureMilliseconds: captureMilliseconds,
            jpegEncodeMilliseconds: jpegEncodeMilliseconds,
            jpegQuality: jpegResult.quality,
            usedDegradedJPEGProfile: request.degradedJPEGProfile != nil,
            request: request
        )
    }

    private static func prepare(
        frame: ScreenDataWire,
        damageReport: RemoteDesktopDamageReport?,
        captureMilliseconds: Int,
        jpegEncodeMilliseconds: Int,
        jpegQuality: CGFloat,
        usedDegradedJPEGProfile: Bool,
        request: Request
    ) -> ProcessingResult {
        let isIndependentFrame = RemoteDesktopScreenFrameWire.containsSyncFrame(
            format: frame.format,
            imageData: frame.imageData,
            advertisedSyncFrame: frame.isSyncFrame
        )
        let plaintext = RemoteDesktopScreenFrameWire.encode(
            width: frame.width,
            height: frame.height,
            imageData: frame.imageData,
            timestamp: frame.timestamp,
            format: frame.format,
            isSyncFrame: frame.isSyncFrame,
            sequenceNumber: frame.sequenceNumber
        )

        do {
            let encryptedPayload = try WebRTCControlChannelCodec.encryptAppPayload(
                plaintext,
                with: request.keys,
                packetType: .remoteDesktop,
                counter: request.secureCounter
            )
            return .prepared(
                PreparedFrame(
                    requestID: request.id,
                    frame: frame,
                    encryptedPayload: encryptedPayload,
                    damageReport: damageReport,
                    captureMilliseconds: captureMilliseconds,
                    jpegEncodeMilliseconds: jpegEncodeMilliseconds,
                    jpegQuality: jpegQuality,
                    usedDegradedJPEGProfile: usedDegradedJPEGProfile,
                    isIndependentFrame: isIndependentFrame,
                    secureStateFingerprint: request.secureStateFingerprint
                )
            )
        } catch {
            return .encryptionFailed(String(describing: error))
        }
    }
}
#endif
