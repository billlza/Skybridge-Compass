import Foundation

enum FileTransferPathPolicy {
    static func sanitizedFileName(_ raw: String) -> String {
        let lastPathComponent = (raw as NSString).lastPathComponent
        let trimmed = lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/", trimmed != "." else {
            return "SkyBridgeFile"
        }
        return trimmed
    }

    static func uniqueDestinationURL(baseDirectory: URL, fileName: String) -> URL {
        let safeName = sanitizedFileName(fileName)
        let ext = (safeName as NSString).pathExtension
        let stem = (safeName as NSString).deletingPathExtension

        var candidate = baseDirectory.appendingPathComponent(safeName, isDirectory: false)
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

        return candidate
    }
}
