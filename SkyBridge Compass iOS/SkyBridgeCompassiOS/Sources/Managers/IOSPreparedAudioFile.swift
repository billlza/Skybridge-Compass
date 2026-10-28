import Foundation
import class SkyBridgeProtocolCore.PreparedOutboundFileReadSession
import enum SkyBridgeProtocolCore.PreparedOutboundFileReadError
import enum SkyBridgeProtocolCore.AudioWavePCMFile
import enum SkyBridgeProtocolCore.AudioWavePCMFileError
import struct SkyBridgeProtocolCore.AudioWavePCMMetadata
import enum SkyBridgeProtocolCore.AudioFlacFile
import struct SkyBridgeProtocolCore.AudioFlacMetadata
import struct SkyBridgeAudioFile.AudioIndexedAlacFile
import struct SkyBridgeProtocolCore.AudioAlacMetadata
import enum SkyBridgeProtocolCore.AudioStreamingWire
import struct SkyBridgeProtocolCore.AudioStreamingPCMFormat
import enum SkyBridgeProtocolCore.ClassicTransferInboundPolicy
import enum SkyBridgeProtocolCore.ClassicTransferMetadataContract

enum IOSPreparedAudioFileError: Error, Equatable, Sendable {
    case invalidSource, invalidTransferID, busy, notPrepared, alreadyClaimed, closed, preparationAlreadyAttempted
}

/// The shared preparation API did not return the descriptor whose cleanup failed.
/// Retaining this owner preserves its scope and diagnostic, but cannot recover that
/// unknown descriptor. Retrying close must not pretend release was confirmed.
struct IOSPreparedAudioFileCleanupUnconfirmed: Error, Sendable {
    let underlying: any Error
}

/// A selected byte source, not account authority, a transfer receipt or playback.
/// Keep this owner until explicit close succeeds. There is no deinit cleanup that
/// silently releases a security scope while an asynchronous read still owns it.
actor IOSPreparedAudioFile {
    enum Source: Sendable {
        case wave(AudioWavePCMMetadata)
        case flac(AudioFlacMetadata)
        case alac(AudioAlacMetadata)
    }
    struct Content: Sendable {
        let transferID: String
        let fileName: String
        let length: Int64
        let digest: Data
        let source: Source
        var format: AudioStreamingPCMFormat {
            switch source {
            case .wave(let value): value.format
            case .flac(let value): value.decodedFormat
            case .alac(let value): value.decodedFormat
            }
        }
        var frameCount: UInt64? {
            switch source {
            case .wave(let value): value.frameCount
            case .flac(let value): value.totalFrames
            case .alac(let value): value.totalFrames
            }
        }
        var isFLAC: Bool { if case .flac = source { true } else { false } }
        var requiresReceiverValidation: Bool {
            switch source { case .wave: false; case .flac, .alac: true }
        }
        var requiredReceiverCapability: String {
            switch source {
            case .wave: AudioStreamingWire.fileReceiveCapability
            case .flac: AudioStreamingWire.flacFileReceiveCapability
            case .alac: AudioStreamingWire.alacFileReceiveCapability
            }
        }
        var mimeType: String {
            switch source { case .wave: "audio/wav"; case .flac: "audio/flac"; case .alac: "audio/mp4" }
        }
        /// Format-specific PCM ranges exist only for WAVE; FLAC and ALAC are transmitted encoded.
        var wave: AudioWavePCMMetadata? { if case .wave(let value) = source { value } else { nil } }
        // Reserved for the unique claimForSending consumer. It must await its
        // entire sending task before closing this source owner. A chunk helper
        // may close this reader; that does not release the owner's URL scope.
        let reader: PreparedOutboundFileReadSession
    }

    nonisolated let transferID: String
    nonisolated let fileName: String
    private let url: URL
    private let startScope: @Sendable (URL) -> Bool
    private let stopScope: @Sendable (URL) -> Void
    private var hasScope = false
    private var attemptedPreparation = false
    private var claimed = false
    private var closing = false
    private(set) var isClosed = false
    private var content: Content?
    private var reader: PreparedOutboundFileReadSession?
    private var preparing: Task<Content, Error>?
    private var reading: ReadOperation?
    private var closeOperation: CloseOperation?
    private var unconfirmedPreparationCleanup: (any Error)?

    private struct ReadOperation: Sendable { let id: UUID; let task: Task<Data, Error> }
    private struct CloseOperation: Sendable { let id: UUID; let task: Task<Void, Error> }

    init(url: URL, transferID: String = UUID().uuidString,
         startScope: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopScope: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw IOSPreparedAudioFileError.invalidSource
        }
        guard transferID.utf8.count == 36, let identifier = UUID(uuidString: transferID),
              identifier != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw IOSPreparedAudioFileError.invalidTransferID
        }
        try ClassicTransferMetadataContract.validateTransferIdentifier(transferID)
        try ClassicTransferMetadataContract.validateFileName(url.lastPathComponent)
        self.url = url; self.transferID = transferID; fileName = url.lastPathComponent
        self.startScope = startScope; self.stopScope = stopScope
    }

    /// Exactly one preparation attempt. A repeated successful call returns the
    /// same content; a failed attempt never reopens the pathname. The lifetime
    /// callback is bookkeeping only and cannot suppress cancellation checks.
    func prepare(onHashProgress: (@Sendable (Int64, Int64) async throws -> Void)? = nil,
                 validateLifetime: @escaping @Sendable () async throws -> Void = { try Task.checkCancellation() }) async throws -> Content {
        try Task.checkCancellation(); try requireOpen()
        guard !claimed else { throw IOSPreparedAudioFileError.alreadyClaimed }
        guard preparing == nil else { throw IOSPreparedAudioFileError.busy }
        if let content {
            if let onHashProgress {
                try await validateLifetime(); try Task.checkCancellation()
                try await onHashProgress(content.length, content.length)
                try Task.checkCancellation(); try await validateLifetime(); try Task.checkCancellation(); try requireOpen()
                guard !claimed else { throw IOSPreparedAudioFileError.alreadyClaimed }
            }
            return content
        }
        guard !attemptedPreparation else { throw IOSPreparedAudioFileError.preparationAlreadyAttempted }
        attemptedPreparation = true
        // False means no security-scope reference was acquired, as for an ordinary
        // sandbox file. The same URL still needs to pass the real open/read checks;
        // no alternative path, provider conversion or access grant is inferred.
        hasScope = startScope(url)
        let task = Task { try await self.prepareContent(onHashProgress: onHashProgress, validateLifetime: validateLifetime) }
        preparing = task
        defer { preparing = nil }
        do {
            let prepared = try await withTaskCancellationHandler {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: { task.cancel() }
            try requireOpen()
            content = prepared
            return prepared
        } catch {
            retainUnconfirmedPreparationCleanup(error)
            throw error
        }
    }

    func preparedContent() throws -> Content {
        try requireOpen()
        guard !claimed else { throw IOSPreparedAudioFileError.alreadyClaimed }
        guard preparing == nil, let content else { throw IOSPreparedAudioFileError.notPrepared }
        return content
    }

    /// Claims are never rolled back. A failed or canceled sender closes this
    /// owner; retrying a transfer requires a new source owner and transfer ID.
    func claimForSending() throws -> Content {
        let prepared = try preparedContent()
        guard reading == nil else { throw IOSPreparedAudioFileError.busy }
        claimed = true
        return prepared
    }

    /// Before the sending claim, inspection reads are serialized by this owner.
    /// Cancellation and close wait for the actual held-descriptor read to finish.
    func read(offset: UInt64, length: Int) async throws -> Data {
        try Task.checkCancellation()
        let prepared = try preparedContent()
        guard reading == nil else { throw IOSPreparedAudioFileError.busy }
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let bytes = try await prepared.reader.read(offset: offset, length: length)
            try Task.checkCancellation()
            return bytes
        }
        let operation = ReadOperation(id: UUID(), task: task); reading = operation
        defer { if reading?.id == operation.id { reading = nil } }
        let bytes = try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
        try requireOpen()
        return bytes
    }

    /// Does not check caller cancellation. All callers await the same actual close
    /// attempt; failure retains the reader and scope so a later explicit close can
    /// retry. The sender must first await its use of Content.reader to completion.
    func close() async throws {
        if isClosed { return }
        let operation: CloseOperation
        if let existing = closeOperation {
            operation = existing
        } else {
            closing = true
            let preparation = preparing, read = reading?.task
            preparation?.cancel(); read?.cancel()
            let task = Task.detached { try await self.finishClose(preparation: preparation, read: read) }
            operation = CloseOperation(id: UUID(), task: task); closeOperation = operation
        }
        defer { if closeOperation?.id == operation.id { closeOperation = nil } }
        try await operation.task.value
    }

    private func prepareContent(onHashProgress: (@Sendable (Int64, Int64) async throws -> Void)?,
                                validateLifetime: @escaping @Sendable () async throws -> Void) async throws -> Content {
        try Task.checkCancellation()
        let selected = try await PreparedOutboundFileReadSession.prepare(url: url,
            maximumSize: ClassicTransferInboundPolicy.maximumFileSizeBytes, sourcePolicy: .regularFile,
            onHashProgress: onHashProgress,
            validateLifetime: {
                try Task.checkCancellation()
                try await validateLifetime()
                try Task.checkCancellation()
            })
        // Publish ownership before format inspection can fail or suspend. A failed
        // inspection leaves this exact reader available to explicit owner.close.
        reader = selected
        try Task.checkCancellation(); try requireOpen()
        guard selected.metadata.fileSize >= 4 else { throw AudioWavePCMFileError.truncated }
        let read: @Sendable (UInt64, Int) async throws -> Data = { offset, length in
            try Task.checkCancellation(); try await validateLifetime()
            let bytes = try await selected.read(offset: offset, length: length)
            try Task.checkCancellation(); try await validateLifetime()
            return bytes
        }
        let source: Source
        let signature = try await read(0, 4)
        if signature == Data("fLaC".utf8) {
            source = .flac(try await AudioFlacFile.inspect(fileSize: UInt64(selected.metadata.fileSize), read: read))
        } else if ["RIFF", "RIFX", "RF64"].contains(where: { signature == Data($0.utf8) }) {
            source = .wave(try await AudioWavePCMFile.inspect(fileSize: UInt64(selected.metadata.fileSize), read: read))
        } else {
            // File extensions and the M4A container alone do not establish ALAC. The shared
            // inspector validates the container and codec declaration; the receiver decodes fully.
            try await validateLifetime(); try Task.checkCancellation()
            let indexed = try await AudioIndexedAlacFile.inspect(reader: selected,
                requireAuthorization: { try Task.checkCancellation() })
            try Task.checkCancellation(); try await validateLifetime(); try Task.checkCancellation()
            source = .alac(indexed.metadata)
        }
        try Task.checkCancellation(); try requireOpen()
        return Content(transferID: transferID, fileName: fileName, length: selected.metadata.fileSize,
            digest: selected.metadata.contentSHA256, source: source, reader: selected)
    }

    private func finishClose(preparation: Task<Content, Error>?, read: Task<Data, Error>?) async throws {
        if let preparation, case let .failure(error) = await preparation.result {
            retainUnconfirmedPreparationCleanup(error)
        }
        // The read caller still receives its original result/error. Close waits
        // for completion but does not relabel an ordinary read failure as cleanup.
        if let read { _ = await read.result }
        if let failure = unconfirmedPreparationCleanup {
            throw IOSPreparedAudioFileCleanupUnconfirmed(underlying: failure)
        }
        if let reader {
            try await reader.close()
            self.reader = nil
        }
        content = nil
        if hasScope { stopScope(url); hasScope = false }
        isClosed = true
    }

    private func retainUnconfirmedPreparationCleanup(_ error: any Error) {
        guard unconfirmedPreparationCleanup == nil, reader == nil,
              let failure = error as? PreparedOutboundFileReadError else { return }
        switch failure {
        case .cleanupFailed, .closeFailed: unconfirmedPreparationCleanup = error
        default: break
        }
    }

    private func requireOpen() throws {
        guard !closing, !isClosed else { throw IOSPreparedAudioFileError.closed }
    }
}
