import CryptoKit
import Foundation
#if os(macOS)
import Darwin
import OSLog
#endif

public struct WebRTCMediaDiagnosticEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestamp: String
    public let sessionId: String
    public let kind: String
    public let probable: String?
    public let videoFPS: Double?
    public let fallbackProducer: String?
    public let nativeVideoHealth: String?
    public let screenBuffered: Int?
    public let submitted: UInt64?
    public let framesEncoded: UInt64?
    public let framesSent: UInt64?
    public let keyFramesEncoded: UInt64?
    public let packetsSent: UInt64?
    public let bytesSent: UInt64?
    public let codec: String?
    public let encoder: String?
    public let qualityLimit: String?
    public let encodeWidth: UInt64?
    public let encodeHeight: UInt64?
    public let encodeFPS: UInt64?
    public let totalEncodeTime: Double?
    public let targetBitrate: UInt64?
    public let availableOutgoingBitrate: UInt64?
    public let currentRTT: Double?
    public let remoteRTT: Double?
    public let remotePacketsLost: Int64?
    public let remoteJitter: Double?
    public let nack: UInt64?
    public let pli: UInt64?
    public let fir: UInt64?
    public let audioTxCaptured: UInt64?
    public let audioTxEncoded: UInt64?
    public let audioTxSent: UInt64?
    public let audioDrops: UInt64?
    public let audioTxCapturedTotal: UInt64?
    public let audioTxEncodedTotal: UInt64?
    public let audioTxSentTotal: UInt64?
    public let audioDropsTotal: UInt64?
    public let audioRxRecv: UInt64?
    public let audioRxDecoded: UInt64?
    public let audioRxPlayed: UInt64?
    public let audioRxRejected: UInt64?
    public let engineRunning: Bool?
    public let renderedFrames: UInt64?
    public let underflow: UInt64?
    public let startupSilenceFrames: UInt64?
    public let sckCaptured: UInt64?
    public let sckMeaningful: UInt64?
    public let sckEncoded: UInt64?
    public let sckEncodedBytes: UInt64?
    public let sckCaptureFPS: Double?
    public let sckMeaningfulFPS: Double?
    public let sckEncodedFPS: Double?
    public let sckTargetFPS: UInt64?
    public let sckWidth: UInt64?
    public let sckHeight: UInt64?
    public let sckCapturesAudio: Bool?
    public let sckEncodeLatencyP50Ms: Double?
    public let sckEncodeLatencyP95Ms: Double?
    public let sckEncodeLatencyMaxMs: Double?
    public let sckEncodeFailures: UInt64?
    public let validationMode: String?
    public let failureReason: String?

    public init(
        timestamp: Date = Date(),
        sessionId: String,
        kind: String,
        probable: String? = nil,
        videoFPS: Double? = nil,
        fallbackProducer: String? = nil,
        nativeVideoHealth: String? = nil,
        screenBuffered: Int? = nil,
        submitted: UInt64? = nil,
        framesEncoded: UInt64? = nil,
        framesSent: UInt64? = nil,
        keyFramesEncoded: UInt64? = nil,
        packetsSent: UInt64? = nil,
        bytesSent: UInt64? = nil,
        codec: String? = nil,
        encoder: String? = nil,
        qualityLimit: String? = nil,
        encodeWidth: UInt64? = nil,
        encodeHeight: UInt64? = nil,
        encodeFPS: UInt64? = nil,
        totalEncodeTime: Double? = nil,
        targetBitrate: UInt64? = nil,
        availableOutgoingBitrate: UInt64? = nil,
        currentRTT: Double? = nil,
        remoteRTT: Double? = nil,
        remotePacketsLost: Int64? = nil,
        remoteJitter: Double? = nil,
        nack: UInt64? = nil,
        pli: UInt64? = nil,
        fir: UInt64? = nil,
        audioTxCaptured: UInt64? = nil,
        audioTxEncoded: UInt64? = nil,
        audioTxSent: UInt64? = nil,
        audioDrops: UInt64? = nil,
        audioTxCapturedTotal: UInt64? = nil,
        audioTxEncodedTotal: UInt64? = nil,
        audioTxSentTotal: UInt64? = nil,
        audioDropsTotal: UInt64? = nil,
        audioRxRecv: UInt64? = nil,
        audioRxDecoded: UInt64? = nil,
        audioRxPlayed: UInt64? = nil,
        audioRxRejected: UInt64? = nil,
        engineRunning: Bool? = nil,
        renderedFrames: UInt64? = nil,
        underflow: UInt64? = nil,
        startupSilenceFrames: UInt64? = nil,
        sckCaptured: UInt64? = nil,
        sckMeaningful: UInt64? = nil,
        sckEncoded: UInt64? = nil,
        sckEncodedBytes: UInt64? = nil,
        sckCaptureFPS: Double? = nil,
        sckMeaningfulFPS: Double? = nil,
        sckEncodedFPS: Double? = nil,
        sckTargetFPS: UInt64? = nil,
        sckWidth: UInt64? = nil,
        sckHeight: UInt64? = nil,
        sckCapturesAudio: Bool? = nil,
        sckEncodeLatencyP50Ms: Double? = nil,
        sckEncodeLatencyP95Ms: Double? = nil,
        sckEncodeLatencyMaxMs: Double? = nil,
        sckEncodeFailures: UInt64? = nil,
        validationMode: String? = nil,
        failureReason: String? = nil
    ) {
        self.schemaVersion = 1
        self.timestamp = ISO8601DateFormatter().string(from: timestamp)
        self.sessionId = sessionId
        self.kind = kind
        self.probable = probable
        self.videoFPS = videoFPS
        self.fallbackProducer = fallbackProducer
        self.nativeVideoHealth = nativeVideoHealth
        self.screenBuffered = screenBuffered
        self.submitted = submitted
        self.framesEncoded = framesEncoded
        self.framesSent = framesSent
        self.keyFramesEncoded = keyFramesEncoded
        self.packetsSent = packetsSent
        self.bytesSent = bytesSent
        self.codec = codec
        self.encoder = encoder
        self.qualityLimit = qualityLimit
        self.encodeWidth = encodeWidth
        self.encodeHeight = encodeHeight
        self.encodeFPS = encodeFPS
        self.totalEncodeTime = totalEncodeTime
        self.targetBitrate = targetBitrate
        self.availableOutgoingBitrate = availableOutgoingBitrate
        self.currentRTT = currentRTT
        self.remoteRTT = remoteRTT
        self.remotePacketsLost = remotePacketsLost
        self.remoteJitter = remoteJitter
        self.nack = nack
        self.pli = pli
        self.fir = fir
        self.audioTxCaptured = audioTxCaptured
        self.audioTxEncoded = audioTxEncoded
        self.audioTxSent = audioTxSent
        self.audioDrops = audioDrops
        self.audioTxCapturedTotal = audioTxCapturedTotal
        self.audioTxEncodedTotal = audioTxEncodedTotal
        self.audioTxSentTotal = audioTxSentTotal
        self.audioDropsTotal = audioDropsTotal
        self.audioRxRecv = audioRxRecv
        self.audioRxDecoded = audioRxDecoded
        self.audioRxPlayed = audioRxPlayed
        self.audioRxRejected = audioRxRejected
        self.engineRunning = engineRunning
        self.renderedFrames = renderedFrames
        self.underflow = underflow
        self.startupSilenceFrames = startupSilenceFrames
        self.sckCaptured = sckCaptured
        self.sckMeaningful = sckMeaningful
        self.sckEncoded = sckEncoded
        self.sckEncodedBytes = sckEncodedBytes
        self.sckCaptureFPS = sckCaptureFPS
        self.sckMeaningfulFPS = sckMeaningfulFPS
        self.sckEncodedFPS = sckEncodedFPS
        self.sckTargetFPS = sckTargetFPS
        self.sckWidth = sckWidth
        self.sckHeight = sckHeight
        self.sckCapturesAudio = sckCapturesAudio
        self.sckEncodeLatencyP50Ms = sckEncodeLatencyP50Ms
        self.sckEncodeLatencyP95Ms = sckEncodeLatencyP95Ms
        self.sckEncodeLatencyMaxMs = sckEncodeLatencyMaxMs
        self.sckEncodeFailures = sckEncodeFailures
        self.validationMode = validationMode
        self.failureReason = failureReason
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case timestamp
        case sessionId = "session_id"
        case kind
        case probable
        case videoFPS = "video_fps"
        case fallbackProducer
        case nativeVideoHealth
        case screenBuffered
        case submitted
        case framesEncoded
        case framesSent
        case keyFramesEncoded
        case packetsSent
        case bytesSent
        case codec
        case encoder
        case qualityLimit
        case encodeWidth
        case encodeHeight
        case encodeFPS
        case totalEncodeTime
        case targetBitrate
        case availableOutgoingBitrate
        case currentRTT
        case remoteRTT
        case remotePacketsLost
        case remoteJitter
        case nack
        case pli
        case fir
        case audioTxCaptured
        case audioTxEncoded
        case audioTxSent
        case audioDrops
        case audioTxCapturedTotal
        case audioTxEncodedTotal
        case audioTxSentTotal
        case audioDropsTotal
        case audioRxRecv
        case audioRxDecoded
        case audioRxPlayed
        case audioRxRejected
        case engineRunning
        case renderedFrames
        case underflow
        case startupSilenceFrames
        case sckCaptured
        case sckMeaningful
        case sckEncoded
        case sckEncodedBytes
        case sckCaptureFPS
        case sckMeaningfulFPS
        case sckEncodedFPS
        case sckTargetFPS
        case sckWidth
        case sckHeight
        case sckCapturesAudio
        case sckEncodeLatencyP50Ms
        case sckEncodeLatencyP95Ms
        case sckEncodeLatencyMaxMs
        case sckEncodeFailures
        case validationMode
        case failureReason
    }
}

public enum WebRTCMediaDiagnosticWriter {
#if os(macOS)
    private static let logger = Logger(
        subsystem: "com.skybridge.compass",
        category: "WebRTCMediaDiagnostics"
    )

    private static let writeQueue = WebRTCMediaDiagnosticWriteQueue(
        queue: DispatchQueue(
            label: "com.skybridge.webrtc-media-diagnostics",
            qos: .utility,
            autoreleaseFrequency: .workItem
        ),
        maximumPendingCount: 128,
        maximumPendingBytes: 1 * 1_024 * 1_024,
        writeOperation: { data, safeSessionReference in
            try WebRTCMediaDiagnosticFileWriter().appendEncodedLine(
                data,
                safeSessionReference: safeSessionReference
            )
        },
        failureHandler: { error in
            if let error = error as? WebRTCMediaDiagnosticWriteError {
                logger.error(
                    "WebRTC media diagnostic write failed: \(error.safeLogSummary, privacy: .public)"
                )
            } else {
                logger.error("WebRTC media diagnostic write failed: unexpected_error")
            }
        }
    )
#endif

    public static func append(_ event: WebRTCMediaDiagnosticEvent) {
#if os(macOS)
        do {
            var line = try publicDiagnosticJSONData(for: event)
            line.append(0x0a)
            guard writeQueue.enqueue(
                data: line,
                safeSessionReference: safeSessionReference(event.sessionId)
            ) else {
                logger.error(
                    "WebRTC media diagnostic queue reached its bounded count/byte capacity; event dropped"
                )
                return
            }
        } catch let error as WebRTCMediaDiagnosticWriteError {
            logger.error(
                "WebRTC media diagnostic admission failed: \(error.safeLogSummary, privacy: .public)"
            )
        } catch {
            logger.error("WebRTC media diagnostic admission failed: unexpected_error")
        }
#else
        _ = event
#endif
    }

#if os(macOS)
    static func safeSessionReference(_ sessionId: String) -> String {
        let value = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return "ref-missing"
        }
        let boundedUTF8 = value.utf8.prefix(WebRTCMediaDiagnosticFileWriter.maximumLineBytes + 1)
        guard boundedUTF8.count <= WebRTCMediaDiagnosticFileWriter.maximumLineBytes else {
            return "ref-invalid"
        }
        let digest = SHA256.hash(data: Data(boundedUTF8))
        let prefix = digest.prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "ref-\(prefix)"
    }

    static func publicDiagnosticJSONData(for event: WebRTCMediaDiagnosticEvent) throws -> Data {
        try validateStringByteBudget(for: event)

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(event)
        } catch {
            throw WebRTCMediaDiagnosticWriteError.encodingFailed
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: encoded)
        } catch {
            throw WebRTCMediaDiagnosticWriteError.encodingFailed
        }
        guard var payload = jsonObject as? [String: Any] else {
            throw WebRTCMediaDiagnosticWriteError.encodingFailed
        }
        payload.removeValue(forKey: "session_id")
        payload["session_ref"] = safeSessionReference(event.sessionId)
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw WebRTCMediaDiagnosticWriteError.encodingFailed
        }
        do {
            let result = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard result.count <= WebRTCMediaDiagnosticFileWriter.maximumLineBytes else {
                throw WebRTCMediaDiagnosticWriteError.payloadTooLarge
            }
            return result
        } catch let error as WebRTCMediaDiagnosticWriteError {
            throw error
        } catch {
            throw WebRTCMediaDiagnosticWriteError.encodingFailed
        }
    }

    /// Bounds all variable-width fields before JSONEncoder can allocate an arbitrarily large
    /// intermediate object. The final encoded-size check remains authoritative because JSON
    /// escaping can expand otherwise-valid UTF-8.
    private static func validateStringByteBudget(
        for event: WebRTCMediaDiagnosticEvent
    ) throws {
        let stringFields: [String?] = [
            event.sessionId,
            event.kind,
            event.probable,
            event.fallbackProducer,
            event.nativeVideoHealth,
            event.codec,
            event.encoder,
            event.qualityLimit,
            event.validationMode,
            event.failureReason
        ]
        var remainingBytes = WebRTCMediaDiagnosticFileWriter.maximumLineBytes
        for value in stringFields.compactMap({ $0 }) {
            let byteCount = value.utf8.prefix(remainingBytes + 1).count
            guard byteCount <= remainingBytes else {
                throw WebRTCMediaDiagnosticWriteError.payloadTooLarge
            }
            remainingBytes -= byteCount
        }
    }
#endif
}

#if os(macOS)
enum WebRTCMediaDiagnosticWriteError: Error, Equatable {
    case encodingFailed
    case payloadTooLarge
    case lockUnavailable
    case retentionLimitExceeded
    case unsafeFileSystemObject
    case posix(operation: String, code: Int32)

    var safeLogSummary: String {
        switch self {
        case .encodingFailed:
            return "encoding_failed"
        case .payloadTooLarge:
            return "payload_too_large"
        case .lockUnavailable:
            return "lock_unavailable"
        case .retentionLimitExceeded:
            return "retention_limit_exceeded"
        case .unsafeFileSystemObject:
            return "unsafe_filesystem_object"
        case .posix(let operation, let code):
            return "posix_\(operation)_\(code)"
        }
    }
}

final class WebRTCMediaDiagnosticWriteQueue: @unchecked Sendable {
    typealias WriteOperation = @Sendable (Data, String) throws -> Void
    typealias FailureHandler = @Sendable (Error) -> Void

    private struct PendingEntry: Sendable {
        let data: Data
        let safeSessionReference: String
    }

    private let queue: DispatchQueue
    private let maximumPendingCount: Int
    private let maximumPendingBytes: Int
    private let writeOperation: WriteOperation
    private let failureHandler: FailureHandler
    private let lock = NSLock()
    private var pendingEntries: [PendingEntry] = []
    private var pendingCount = 0
    private var pendingBytes = 0
    private var isDraining = false

    init(
        queue: DispatchQueue,
        maximumPendingCount: Int,
        maximumPendingBytes: Int,
        writeOperation: @escaping WriteOperation,
        failureHandler: @escaping FailureHandler
    ) {
        precondition(maximumPendingCount > 0)
        precondition(maximumPendingBytes > 0)
        self.queue = queue
        self.maximumPendingCount = maximumPendingCount
        self.maximumPendingBytes = maximumPendingBytes
        self.writeOperation = writeOperation
        self.failureHandler = failureHandler
    }

    @discardableResult
    func enqueue(data: Data, safeSessionReference: String) -> Bool {
        var shouldScheduleDrain = false
        lock.lock()
        let canAccept = !data.isEmpty
            && data.count <= maximumPendingBytes
            && safeSessionReference.utf8.prefix(33).count <= 32
            && pendingCount < maximumPendingCount
            && pendingBytes <= maximumPendingBytes - data.count
        if canAccept {
            pendingEntries.append(
                PendingEntry(data: data, safeSessionReference: safeSessionReference)
            )
            pendingCount += 1
            pendingBytes += data.count
            if !isDraining {
                isDraining = true
                shouldScheduleDrain = true
            }
        }
        lock.unlock()

        if shouldScheduleDrain {
            queue.async { [weak self] in
                self?.drain()
            }
        }
        return canAccept
    }

#if DEBUG || SKYBRIDGE_TESTING
    func flushForTesting() {
        queue.sync {}
    }

    func pendingSnapshotForTesting() -> (count: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (pendingCount, pendingBytes)
    }
#endif

    private func drain() {
        while true {
            let entry: PendingEntry
            lock.lock()
            guard !pendingEntries.isEmpty else {
                isDraining = false
                lock.unlock()
                return
            }
            entry = pendingEntries.removeFirst()
            lock.unlock()

            do {
                try writeOperation(entry.data, entry.safeSessionReference)
            } catch {
                failureHandler(error)
            }

            lock.lock()
            pendingCount -= 1
            pendingBytes -= entry.data.count
            lock.unlock()
        }
    }
}

struct WebRTCMediaDiagnosticFileWriter {
    static let maximumLineBytes = 64 * 1_024
    static let maximumLogFileBytes = 8 * 1_024 * 1_024
    static let maximumRetainedBytes = 32 * 1_024 * 1_024
    static let maximumRetainedFileCount = 8

    typealias LockAttempt = @Sendable (Int32) -> Int32

    private struct RetainedLogFile {
        let name: String
        let size: Int
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private let logsRootURL: URL
    private let maximumFileBytes: Int
    private let maximumTotalBytes: Int
    private let maximumFileCount: Int
    private let lockAttempt: LockAttempt
    private let lockRetryCount: Int
    private let lockRetryDelayMicroseconds: UInt32

    init(
        logsRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true),
        maximumFileBytes: Int = Self.maximumLogFileBytes,
        maximumTotalBytes: Int = Self.maximumRetainedBytes,
        maximumFileCount: Int = Self.maximumRetainedFileCount,
        lockRetryCount: Int = 20,
        lockRetryDelayMicroseconds: UInt32 = 5_000,
        lockAttempt: @escaping LockAttempt = { descriptor in
            Darwin.lockf(descriptor, F_TLOCK, 0) == 0 ? 0 : errno
        }
    ) {
        precondition(maximumFileBytes > 0)
        precondition(maximumTotalBytes >= maximumFileBytes)
        precondition(maximumFileCount > 0)
        precondition(lockRetryCount > 0)
        self.logsRootURL = logsRootURL
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumFileCount = maximumFileCount
        self.lockAttempt = lockAttempt
        self.lockRetryCount = lockRetryCount
        self.lockRetryDelayMicroseconds = lockRetryDelayMicroseconds
    }

    func append(_ event: WebRTCMediaDiagnosticEvent) throws {
        var line = try WebRTCMediaDiagnosticWriter.publicDiagnosticJSONData(for: event)
        line.append(0x0a)
        try appendEncodedLine(
            line,
            safeSessionReference: WebRTCMediaDiagnosticWriter.safeSessionReference(event.sessionId)
        )
    }

    func appendEncodedLine(
        _ line: Data,
        safeSessionReference: String
    ) throws {
        guard !line.isEmpty,
              line.last == 0x0a,
              line.count <= Self.maximumLineBytes + 1,
              line.count <= maximumFileBytes else {
            throw WebRTCMediaDiagnosticWriteError.payloadTooLarge
        }
        guard Self.isSafeSessionReference(safeSessionReference) else {
            throw WebRTCMediaDiagnosticWriteError.unsafeFileSystemObject
        }

        let rootDescriptor = try openTrustedDirectory(at: logsRootURL)
        defer { _ = Darwin.close(rootDescriptor) }
        let logsDescriptor = try openOrCreateTrustedDirectory(
            named: "SkyBridge",
            parentDescriptor: rootDescriptor
        )
        defer { _ = Darwin.close(logsDescriptor) }

        let lockDescriptor = try openTrustedLogFile(
            named: ".webrtc-media.lock",
            directoryDescriptor: logsDescriptor
        )
        do {
            try acquireBoundedLock(lockDescriptor)
            try appendWhileLocked(
                line,
                safeSessionReference: safeSessionReference,
                directoryDescriptor: logsDescriptor
            )
        } catch {
            let operationError = error
            _ = Darwin.close(lockDescriptor)
            throw operationError
        }
        guard Darwin.close(lockDescriptor) == 0 else {
            throw posixError("close_lock")
        }
    }

    private func appendWhileLocked(
        _ line: Data,
        safeSessionReference: String,
        directoryDescriptor: Int32
    ) throws {
        let filename = "webrtc-media-\(safeSessionReference).jsonl"
        let rotatedFilename = "\(filename).1"
        var fileDescriptor = try openTrustedLogFile(
            named: filename,
            directoryDescriptor: directoryDescriptor
        )
        var fileIsOpen = true
        defer {
            if fileIsOpen {
                _ = Darwin.close(fileDescriptor)
            }
        }

        var metadata = try validatedFileMetadata(fileDescriptor)
        guard metadata.st_size >= 0,
              metadata.st_size <= off_t(Int.max) else {
            throw WebRTCMediaDiagnosticWriteError.retentionLimitExceeded
        }

        if Int(metadata.st_size) > maximumFileBytes - line.count {
            guard Darwin.close(fileDescriptor) == 0 else {
                fileIsOpen = false
                throw posixError("close_before_rotation")
            }
            fileIsOpen = false
            try removeRetainedFileIfPresent(
                named: rotatedFilename,
                directoryDescriptor: directoryDescriptor
            )
            guard Darwin.renameat(
                directoryDescriptor,
                filename,
                directoryDescriptor,
                rotatedFilename
            ) == 0 else {
                throw posixError("rotate")
            }
            try synchronizeDescriptor(directoryDescriptor)

            fileDescriptor = try openTrustedLogFile(
                named: filename,
                directoryDescriptor: directoryDescriptor
            )
            fileIsOpen = true
            metadata = try validatedFileMetadata(fileDescriptor)
            guard metadata.st_size == 0 else {
                throw WebRTCMediaDiagnosticWriteError.unsafeFileSystemObject
            }
        }

        try reserveRetentionCapacity(
            forAdditionalBytes: line.count,
            protecting: filename,
            directoryDescriptor: directoryDescriptor
        )
        try writeAll(line, to: fileDescriptor)

        guard Darwin.close(fileDescriptor) == 0 else {
            fileIsOpen = false
            throw posixError("close_file")
        }
        fileIsOpen = false
    }

    private func reserveRetentionCapacity(
        forAdditionalBytes additionalBytes: Int,
        protecting protectedFilename: String,
        directoryDescriptor: Int32
    ) throws {
        var files = try retainedLogFiles(directoryDescriptor: directoryDescriptor)
        var totalBytes = try files.reduce(into: 0) { total, file in
            guard file.size >= 0, total <= Int.max - file.size else {
                throw WebRTCMediaDiagnosticWriteError.retentionLimitExceeded
            }
            total += file.size
        }
        var removedFile = false

        while totalBytes > maximumTotalBytes - additionalBytes
                || files.count > maximumFileCount {
            guard let victimIndex = files.indices
                .filter({ files[$0].name != protectedFilename })
                .min(by: { Self.retentionOrder(files[$0], files[$1]) }) else {
                throw WebRTCMediaDiagnosticWriteError.retentionLimitExceeded
            }
            let victim = files.remove(at: victimIndex)
            guard Darwin.unlinkat(directoryDescriptor, victim.name, 0) == 0 else {
                throw posixError("prune")
            }
            totalBytes -= victim.size
            removedFile = true
        }

        if removedFile {
            try synchronizeDescriptor(directoryDescriptor)
        }
    }

    private func retainedLogFiles(
        directoryDescriptor: Int32
    ) throws -> [RetainedLogFile] {
        let scanDescriptor = Darwin.dup(directoryDescriptor)
        guard scanDescriptor >= 0 else { throw posixError("duplicate_directory") }
        guard let directory = Darwin.fdopendir(scanDescriptor) else {
            _ = Darwin.close(scanDescriptor)
            throw posixError("open_directory_stream")
        }
        defer { _ = Darwin.closedir(directory) }

        var files: [RetainedLogFile] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else { throw posixError("read_directory") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard Self.isRetainedLogFilename(name) else { continue }

            var metadata = stat()
            guard Darwin.fstatat(
                directoryDescriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw posixError("stat_retained_file")
            }
            try validateFileMetadata(metadata)
            guard metadata.st_size >= 0,
                  metadata.st_size <= off_t(Int.max) else {
                throw WebRTCMediaDiagnosticWriteError.retentionLimitExceeded
            }
            files.append(
                RetainedLogFile(
                    name: name,
                    size: Int(metadata.st_size),
                    modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
                    modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
                )
            )
        }
        return files
    }

    private static func retentionOrder(
        _ lhs: RetainedLogFile,
        _ rhs: RetainedLogFile
    ) -> Bool {
        (lhs.modifiedSeconds, lhs.modifiedNanoseconds, lhs.name)
            < (rhs.modifiedSeconds, rhs.modifiedNanoseconds, rhs.name)
    }

    private static func isRetainedLogFilename(_ name: String) -> Bool {
        guard name.hasPrefix("webrtc-media-ref-") else { return false }
        return name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.1")
    }

    private static func isSafeSessionReference(_ value: String) -> Bool {
        guard value == "ref-missing" || value == "ref-invalid"
                || (value.hasPrefix("ref-") && value.utf8.count == 20) else {
            return false
        }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 97 && $0 <= 102)
                || $0 == 45
                || ($0 >= 103 && $0 <= 122)
        }
    }

    private func removeRetainedFileIfPresent(
        named name: String,
        directoryDescriptor: Int32
    ) throws {
        var metadata = stat()
        if Darwin.fstatat(
            directoryDescriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            if errno == ENOENT { return }
            throw posixError("stat_rotation_target")
        }
        try validateFileMetadata(metadata)
        guard Darwin.unlinkat(directoryDescriptor, name, 0) == 0 else {
            throw posixError("remove_rotation_target")
        }
    }

    private func openTrustedDirectory(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw posixError("open_root") }
        do {
            try validateDirectory(descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openOrCreateTrustedDirectory(
        named name: String,
        parentDescriptor: Int32
    ) throws -> Int32 {
        var descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0, errno == ENOENT {
            guard Darwin.mkdirat(parentDescriptor, name, 0o700) == 0 else {
                if errno != EEXIST { throw posixError("mkdir") }
                descriptor = Darwin.openat(
                    parentDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard descriptor >= 0 else { throw posixError("open_directory") }
                do {
                    try validateDirectory(descriptor)
                    return descriptor
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw posixError("sync_parent")
            }
            descriptor = Darwin.openat(
                parentDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { throw posixError("open_directory") }
        do {
            try validateDirectory(descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func validateDirectory(_ descriptor: Int32) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw posixError("stat_directory")
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o022 == 0 else {
            throw WebRTCMediaDiagnosticWriteError.unsafeFileSystemObject
        }
    }

    private func openTrustedLogFile(
        named name: String,
        directoryDescriptor: Int32
    ) throws -> Int32 {
        var descriptor = Darwin.openat(
            directoryDescriptor,
            name,
            O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        if descriptor < 0, errno == EEXIST {
            descriptor = Darwin.openat(
                directoryDescriptor,
                name,
                O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
            )
        } else if descriptor >= 0 {
            if Darwin.fsync(directoryDescriptor) != 0 {
                let syncError = posixError("sync_directory")
                Darwin.close(descriptor)
                throw syncError
            }
        }
        guard descriptor >= 0 else { throw posixError("open_file") }

        do {
            _ = try validatedFileMetadata(descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func validatedFileMetadata(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posixError("stat_file")
        }
        try validateFileMetadata(metadata)
        return metadata
    }

    private func validateFileMetadata(_ metadata: stat) throws {
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600 else {
            throw WebRTCMediaDiagnosticWriteError.unsafeFileSystemObject
        }
    }

    private func acquireBoundedLock(_ descriptor: Int32) throws {
        for attempt in 0..<lockRetryCount {
            let result = lockAttempt(descriptor)
            if result == 0 { return }
            if result != EINTR && result != EAGAIN && result != EACCES {
                throw WebRTCMediaDiagnosticWriteError.posix(
                    operation: "lock_file",
                    code: result
                )
            }
            guard attempt + 1 < lockRetryCount else {
                throw WebRTCMediaDiagnosticWriteError.lockUnavailable
            }
            if lockRetryDelayMicroseconds > 0 {
                _ = Darwin.usleep(lockRetryDelayMicroseconds)
            }
        }
        throw WebRTCMediaDiagnosticWriteError.lockUnavailable
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw posixError("write_file")
                }
            }
        }
    }

    private func posixError(_ operation: String) -> WebRTCMediaDiagnosticWriteError {
        .posix(operation: operation, code: errno)
    }

    private func synchronizeDescriptor(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixError("sync_directory")
        }
    }
}
#endif

public struct RealtimeMediaAudioSenderDiagnosticSnapshot: Codable, Equatable, Sendable {
    public let capturedPackets: UInt64
    public let encodedPackets: UInt64
    public let sentPackets: UInt64
    public let droppedPackets: UInt64
    public let invalidDroppedPackets: UInt64
    public let overflowDroppedPackets: UInt64
    public let staleDroppedPackets: UInt64
    public let sendFailedPackets: UInt64
    public let emptyPacingTicks: UInt64
    public let queuedFrames: Int
    public let queuedMs: Int
    public let mode: String
}

public struct RealtimeMediaAudioReceiverDiagnosticSnapshot: Codable, Equatable, Sendable {
    public let receivedPackets: UInt64
    public let decodedPackets: UInt64
    public let playedPackets: UInt64
    public let rejectedPackets: UInt64
    public let plcFrames: UInt64
    public let mode: String
}
