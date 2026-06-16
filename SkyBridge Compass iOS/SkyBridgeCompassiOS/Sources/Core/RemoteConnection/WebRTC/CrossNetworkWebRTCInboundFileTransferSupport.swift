import CryptoKit
import Foundation

@available(iOS 17.0, *)
enum CrossNetworkWebRTCInboundFileTransferPathError: Error {
    case emptyFileName
    case traversalComponent
    case pathSeparator
    case destinationEscapesBaseDirectory
}

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    private nonisolated static let inboundFileNameFallback = "SkyBridgeFile"

    nonisolated static func fileTransferWaiterKey(
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

    nonisolated static func sanitizeFileName(_ name: String) -> String {
        (try? validatedInboundFileName(name)) ?? inboundFileNameFallback
    }

    nonisolated static func makeUniqueDestinationURL(baseDir: URL, fileName: String) throws -> URL {
        let safe = try validatedInboundFileName(fileName)
        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        let canonicalBaseDir = baseDir
            .resolvingSymlinksInPath()
            .standardizedFileURL

        var candidate = canonicalBaseDir.appendingPathComponent(safe, isDirectory: false)
        var idx = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let altName: String
            if ext.isEmpty {
                altName = "\(stem) (\(idx))"
            } else {
                altName = "\(stem) (\(idx)).\(ext)"
            }
            candidate = canonicalBaseDir.appendingPathComponent(altName, isDirectory: false)
            idx += 1
        }
        guard isInboundDestination(candidate, containedIn: canonicalBaseDir) else {
            throw CrossNetworkWebRTCInboundFileTransferPathError.destinationEscapesBaseDirectory
        }
        return candidate
    }

    nonisolated static func expectedInboundChunkCount(fileSize: Int64, chunkSize: Int) -> Int? {
        guard chunkSize > 0 else { return nil }
        if fileSize == 0 { return 0 }
        let total = (fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)
        guard total >= 0, total <= Int64(Int.max) else { return nil }
        return Int(total)
    }

    nonisolated static func validateInboundMetadata(
        fileName: String,
        fileSize: Int64,
        chunkSize: Int,
        totalChunks: Int
    ) -> String? {
        guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Invalid metadata (empty fileName)"
        }
        do {
            _ = try validatedInboundFileName(fileName)
        } catch {
            return "Invalid metadata (unsafe fileName)"
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

    nonisolated static func expectedInboundChunkSize(
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

    nonisolated static func sha256File(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = Data(hasher.finalize())
        try handle.close()
        return digest
    }

    private nonisolated static func validatedInboundFileName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CrossNetworkWebRTCInboundFileTransferPathError.emptyFileName
        }
        guard trimmed != "." && trimmed != ".." else {
            throw CrossNetworkWebRTCInboundFileTransferPathError.traversalComponent
        }
        guard !containsInboundPathSeparator(trimmed) else {
            throw CrossNetworkWebRTCInboundFileTransferPathError.pathSeparator
        }
        return trimmed
    }

    private nonisolated static func containsInboundPathSeparator(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x00, 0x2F, 0x5C, 0x2044, 0x2215:
                return true
            default:
                return false
            }
        }
    }

    private nonisolated static func isInboundDestination(_ candidate: URL, containedIn baseDirectory: URL) -> Bool {
        let candidatePath = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let basePath = baseDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let normalizedBasePath = basePath.hasSuffix("/") ? basePath : basePath + "/"
        return candidatePath.hasPrefix(normalizedBasePath)
    }
}
