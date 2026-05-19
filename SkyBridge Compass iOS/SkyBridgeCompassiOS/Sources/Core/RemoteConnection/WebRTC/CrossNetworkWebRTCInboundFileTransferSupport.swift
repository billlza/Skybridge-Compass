import CryptoKit
import Foundation

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    static func fileTransferWaiterKey(
        transferId: String,
        op: CrossNetworkFileTransferOp,
        chunkIndex: Int?
    ) -> String {
        let idx = chunkIndex ?? -1
        return "\(transferId)|\(op.rawValue)|\(idx)"
    }

    static func downloadsDirectoryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func sanitizeFileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "SkyBridgeFile" : trimmed
    }

    static func makeUniqueDestinationURL(baseDir: URL, fileName: String) -> URL {
        let safe = sanitizeFileName(fileName)
        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension

        var candidate = baseDir.appendingPathComponent(safe)
        var idx = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let altName: String
            if ext.isEmpty {
                altName = "\(stem) (\(idx))"
            } else {
                altName = "\(stem) (\(idx)).\(ext)"
            }
            candidate = baseDir.appendingPathComponent(altName)
            idx += 1
        }
        return candidate
    }

    static func expectedInboundChunkCount(fileSize: Int64, chunkSize: Int) -> Int? {
        guard chunkSize > 0 else { return nil }
        if fileSize == 0 { return 0 }
        let total = (fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)
        guard total >= 0, total <= Int64(Int.max) else { return nil }
        return Int(total)
    }

    static func validateInboundMetadata(
        fileName: String,
        fileSize: Int64,
        chunkSize: Int,
        totalChunks: Int
    ) -> String? {
        guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Invalid metadata (empty fileName)"
        }
        guard fileSize >= 0 else {
            return "Invalid metadata (negative fileSize)"
        }
        let maxInboundChunkSize = 512 * 1024
        guard chunkSize > 0, chunkSize <= maxInboundChunkSize else {
            return "Invalid metadata (chunkSize out of range)"
        }
        guard totalChunks >= 0 else {
            return "Invalid metadata (negative totalChunks)"
        }
        guard let expectedTotalChunks = expectedInboundChunkCount(fileSize: fileSize, chunkSize: chunkSize),
              expectedTotalChunks == totalChunks else {
            return "Invalid metadata (fileSize/chunkSize/totalChunks mismatch)"
        }
        return nil
    }

    static func expectedInboundChunkSize(
        fileSize: Int64,
        chunkSize: Int,
        totalChunks: Int,
        index: Int
    ) -> Int? {
        guard index >= 0, index < totalChunks else { return nil }
        let offset = Int64(index) * Int64(chunkSize)
        guard offset >= 0, offset <= fileSize else { return nil }
        let remaining = fileSize - offset
        guard remaining >= 0 else { return nil }
        return Int(min(Int64(chunkSize), remaining))
    }

    static func sha256File(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}
