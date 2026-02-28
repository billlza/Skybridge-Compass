// SPDX-License-Identifier: MIT
// SkyBridge Compass - Artifact Path Helper

import Foundation

public enum ArtifactPaths {
    /// Resolve a writable artifacts directory.
    ///
    /// Priority:
    /// - `ARTIFACTS_DIR` (preferred)
    /// - `SKYBRIDGE_ARTIFACTS_DIR` (compat)
    /// - `<repo>/Artifacts` when writable
    /// - `<cwd>/Artifacts` when writable
    /// - `<temporaryDirectory>/SkyBridgeArtifacts`
    public static func writableArtifactsDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let envCandidates = [
            environment["ARTIFACTS_DIR"],
            environment["SKYBRIDGE_ARTIFACTS_DIR"]
        ].compactMap { raw -> URL? in
            guard let raw, !raw.isEmpty else { return nil }
            return URL(fileURLWithPath: raw, isDirectory: true)
        }

        for candidate in envCandidates {
            if let writable = ensureWritableDirectory(candidate, fileManager: fileManager) {
                return writable
            }
        }

        if let repoRoot = repositoryRoot(fileManager: fileManager) {
            let repoArtifacts = repoRoot.appendingPathComponent("Artifacts", isDirectory: true)
            if let writable = ensureWritableDirectory(repoArtifacts, fileManager: fileManager) {
                return writable
            }
        }

        let cwdArtifacts = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Artifacts", isDirectory: true)
        if let writable = ensureWritableDirectory(cwdArtifacts, fileManager: fileManager) {
            return writable
        }

        let fallback = fileManager.temporaryDirectory
            .appendingPathComponent("SkyBridgeArtifacts", isDirectory: true)
        if let writable = ensureWritableDirectory(fallback, fileManager: fileManager) {
            return writable
        }

        return fileManager.temporaryDirectory
    }

    private static func repositoryRoot(fileManager: FileManager) -> URL? {
        var current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

        while true {
            let packageManifest = current.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: packageManifest.path) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    private static func ensureWritableDirectory(_ directory: URL, fileManager: FileManager) -> URL? {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let probe = directory.appendingPathComponent(".artifacts-write-probe-\(UUID().uuidString)")
            try Data().write(to: probe, options: .atomic)
            try? fileManager.removeItem(at: probe)
            return directory
        } catch {
            return nil
        }
    }
}
