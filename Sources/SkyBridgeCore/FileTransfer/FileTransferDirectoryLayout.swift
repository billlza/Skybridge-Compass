import Foundation

/// Canonical filesystem locations owned by the shared file-transfer subsystem.
///
/// macOS keeps its existing user-visible Downloads layout. iOS uses the app container's
/// Documents/Downloads directory; it must never derive a path from the macOS-only
/// `homeDirectoryForCurrentUser` API. Missing system search-path directories are represented as
/// `nil` so callers can either try an explicitly documented alternative or fail with a typed I/O
/// error. This type does not invent temporary or process-working-directory fallbacks.
enum FileTransferDirectoryLayout {
    enum Platform: Sendable {
        case macOS
        case iOS
    }

    static func classicInboundPartialDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SkyBridge", isDirectory: true)
            .appendingPathComponent("ClassicInboundPartials", isDirectory: true)
    }

    static func defaultReceiveDirectory() -> URL? {
        #if os(macOS)
        return defaultReceiveDirectory(
            platform: .macOS,
            downloadsDirectory: FileManager.default.urls(
                for: .downloadsDirectory,
                in: .userDomainMask
            ).first,
            documentsDirectory: nil
        )
        #else
        return defaultReceiveDirectory(
            platform: .iOS,
            downloadsDirectory: nil,
            documentsDirectory: FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        )
        #endif
    }

    static func defaultReceiveDirectory(
        platform: Platform,
        downloadsDirectory: URL?,
        documentsDirectory: URL?
    ) -> URL? {
        switch platform {
        case .macOS:
            return downloadsDirectory?.appendingPathComponent("SkyBridge", isDirectory: true)
        case .iOS:
            // Preserve the existing iOS owner's durable layout so adopting the shared manager
            // does not orphan files or history entries created under Documents/Downloads.
            return documentsDirectory?.appendingPathComponent("Downloads", isDirectory: true)
        }
    }

    static func applicationSupportReceiveDirectory() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("SkyBridge", isDirectory: true)
            .appendingPathComponent("Received Files", isDirectory: true)
    }

    static func receiveDirectoryCandidates(
        platform: Platform,
        explicitDirectory: URL?,
        defaultDirectory: URL?,
        applicationSupportDirectory: URL?
    ) -> [URL] {
        let rawCandidates: [URL?]
        switch platform {
        case .macOS:
            rawCandidates = [
                explicitDirectory,
                defaultDirectory,
                applicationSupportDirectory
            ]
        case .iOS:
            // Received files are user-visible documents on iOS. Falling back to
            // Application Support would make a successful transfer disappear from
            // the documented Documents/Downloads owner and silently fork storage.
            rawCandidates = [explicitDirectory, defaultDirectory]
        }

        var seenPaths = Set<String>()
        return rawCandidates.compactMap { candidate in
            guard let candidate else { return nil }
            let standardized = candidate.standardizedFileURL
            return seenPaths.insert(standardized.path).inserted ? standardized : nil
        }
    }

    static func receiveDirectoryCandidates(
        explicitDirectory: URL?,
        defaultDirectory: URL?,
        applicationSupportDirectory: URL?
    ) -> [URL] {
        #if os(macOS)
        let platform: Platform = .macOS
        #else
        let platform: Platform = .iOS
        #endif
        return receiveDirectoryCandidates(
            platform: platform,
            explicitDirectory: explicitDirectory,
            defaultDirectory: defaultDirectory,
            applicationSupportDirectory: applicationSupportDirectory
        )
    }
}
