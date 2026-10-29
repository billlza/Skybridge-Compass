import Foundation
import SkyBridgeProtocolCore

/// Container declarations tied to one held, commitment-verified reader. This is not a decoded
/// file witness or output permission. The outer transfer owner retains and closes the reader.
public struct AudioIndexedAlacFile: Sendable {
    public let reader: PreparedOutboundFileReadSession
    public let metadata: AudioAlacMetadata

    private init(reader: PreparedOutboundFileReadSession, metadata: AudioAlacMetadata) {
        self.reader = reader; self.metadata = metadata
    }

    public static func inspect(reader: PreparedOutboundFileReadSession,
        requireAuthorization: @escaping @Sendable () throws -> Void
    ) async throws -> AudioIndexedAlacFile {
        let check: @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try requireAuthorization()
            try Task.checkCancellation()
        }
        try check()
        let metadata = try await reader.withSynchronousVerifiedReads { read, validateSource in
            try validateSource(); try check()
            let value = try AudioAlacFile.inspect(fileSize: UInt64(reader.metadata.fileSize),
                read: read, requireCurrent: check)
            try validateSource(); try check()
            return value
        }
        try check()
        return AudioIndexedAlacFile(reader: reader, metadata: metadata)
    }
}
