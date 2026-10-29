import Foundation

enum FileTransferPathPolicyError: Error, LocalizedError, Equatable {
    case emptyFileName
    case traversalComponent
    case pathSeparator
    case destinationEscapesBaseDirectory

    var errorDescription: String? {
        switch self {
        case .emptyFileName:
            return "Incoming file name is empty."
        case .traversalComponent:
            return "Incoming file name contains a traversal component."
        case .pathSeparator:
            return "Incoming file name contains a path separator."
        case .destinationEscapesBaseDirectory:
            return "Resolved destination escapes the receive directory."
        }
    }
}

enum FileTransferPathPolicy {
    private static let fallbackFileName = "SkyBridgeFile"

    static func validatedFileName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileTransferPathPolicyError.emptyFileName
        }
        guard trimmed != "." && trimmed != ".." else {
            throw FileTransferPathPolicyError.traversalComponent
        }
        guard !containsPathSeparator(trimmed) else {
            throw FileTransferPathPolicyError.pathSeparator
        }
        return trimmed
    }

    static func sanitizedFileName(_ raw: String) -> String {
        do {
            return try validatedFileName(raw)
        } catch {
            return fallbackFileName
        }
    }

    static func uniqueDestinationURL(baseDirectory: URL, fileName: String) throws -> URL {
        let safeName = try validatedFileName(fileName)
        let ext = (safeName as NSString).pathExtension
        let stem = (safeName as NSString).deletingPathExtension

        let canonicalBaseDirectory = baseDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var candidate = canonicalBaseDirectory.appendingPathComponent(safeName, isDirectory: false)
        var index = 1

        while FileManager.default.fileExists(atPath: candidate.path) {
            let alternateName: String
            if ext.isEmpty {
                alternateName = "\(stem) (\(index))"
            } else {
                alternateName = "\(stem) (\(index)).\(ext)"
            }
            candidate = baseDirectory.appendingPathComponent(alternateName, isDirectory: false)
            index += 1
        }

        guard isContained(candidate, in: canonicalBaseDirectory) else {
            throw FileTransferPathPolicyError.destinationEscapesBaseDirectory
        }
        return candidate
    }

    private static func containsPathSeparator(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x00, 0x2F, 0x5C, 0x2044, 0x2215:
                return true
            default:
                return false
            }
        }
    }

    private static func isContained(_ candidate: URL, in baseDirectory: URL) -> Bool {
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
