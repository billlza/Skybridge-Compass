import CryptoKit
import Foundation
import SkyBridgeProtocolCore

enum AudioCaptureReceiveError: Error, Equatable, Sendable {
    case wrongStream, invalidState, invalidWindow, discontinuity, partialFrame
    case windowExceeded, invalidProgress, contentMismatch
}

/// Accounting for the actual captured-PCM receiver. Native acceptance and native
/// retirement are distinct: bytes are hashed only after enqueue succeeds, and
/// credit advances only for source frames removed from that same native queue.
struct AudioCaptureReceiveFlow {
    enum State: Equatable { case receiving, contentVerified, completed }
    let streamID: UUID
    let format: AudioStreamingPCMFormat
    let windowBytes: UInt64
    private(set) var state = State.receiving
    private(set) var receivedBytes: UInt64 = 0
    private(set) var retiredBytes: UInt64 = 0
    private(set) var verifiedDigest: Data?
    private var digest = SHA256()

    init(streamID: UUID, format: AudioStreamingPCMFormat, windowBytes: UInt32) throws {
        guard windowBytes > 0, windowBytes <= AudioStreamingWire.maximumReceiveWindowBytes,
              windowBytes % format.bytesPerFrame == 0 else { throw AudioCaptureReceiveError.invalidWindow }
        // Reuse the immutable wire contract's stream-ID boundary.
        _ = try AudioStreamingWire.encode(.init(streamID: streamID, body: .captureOffer(format)))
        self.streamID = streamID; self.format = format; self.windowBytes = UInt64(windowBytes)
    }

    func validateData(streamID: UUID, offset: UInt64, bytes: Data) throws {
        guard streamID == self.streamID else { throw AudioCaptureReceiveError.wrongStream }
        guard state == .receiving else { throw AudioCaptureReceiveError.invalidState }
        guard offset == receivedBytes, !bytes.isEmpty,
              bytes.count <= AudioStreamingWire.maximumPCMDataBytes,
              offset <= AudioStreamingWire.maximumCounter,
              UInt64(bytes.count) <= AudioStreamingWire.maximumCounter - offset else {
            throw AudioCaptureReceiveError.discontinuity
        }
        guard bytes.count % Int(format.bytesPerFrame) == 0 else { throw AudioCaptureReceiveError.partialFrame }
        guard receivedBytes >= retiredBytes,
              receivedBytes - retiredBytes <= windowBytes,
              UInt64(bytes.count) <= windowBytes - (receivedBytes - retiredBytes) else {
            throw AudioCaptureReceiveError.windowExceeded
        }
    }

    mutating func didEnqueue(streamID: UUID, offset: UInt64, bytes: Data) throws {
        try validateData(streamID: streamID, offset: offset, bytes: bytes)
        digest.update(data: bytes)
        receivedBytes += UInt64(bytes.count)
    }

    /// The caller supplies cumulative *source* frames from its exact native output.
    /// Padding frames never expand sender credit or source-content accounting.
    @discardableResult
    mutating func retire(sourceFrames: UInt64) throws -> UInt64? {
        guard state != .completed,
              sourceFrames <= receivedBytes / UInt64(format.bytesPerFrame) else {
            throw AudioCaptureReceiveError.invalidProgress
        }
        let bytes = sourceFrames * UInt64(format.bytesPerFrame)
        guard bytes >= retiredBytes else { throw AudioCaptureReceiveError.invalidProgress }
        guard bytes > retiredBytes else { return nil }
        retiredBytes = bytes
        return bytes
    }

    mutating func verifyEnd(streamID: UUID, totalBytes: UInt64, sha256: Data) throws -> UInt64 {
        guard streamID == self.streamID else { throw AudioCaptureReceiveError.wrongStream }
        guard state == .receiving else { throw AudioCaptureReceiveError.invalidState }
        guard totalBytes == receivedBytes, sha256.count == 32,
              Data(digest.finalize()) == sha256 else { throw AudioCaptureReceiveError.contentMismatch }
        state = .contentVerified; verifiedDigest = sha256
        return totalBytes / UInt64(format.bytesPerFrame)
    }

    /// This method does not establish native completion; the owner must first
    /// obtain the exact output's bounded drain/progress receipt.
    mutating func didComplete(sourceFrames: UInt64) throws {
        guard state == .contentVerified, retiredBytes == receivedBytes,
              sourceFrames == receivedBytes / UInt64(format.bytesPerFrame) else {
            throw AudioCaptureReceiveError.invalidProgress
        }
        state = .completed
    }
}
