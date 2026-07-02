import Foundation

public actor ApplicationCacheService {
    public static let shared = ApplicationCacheService()

    public enum CacheOperation: String, Sendable, Equatable {
        case measure
        case clear
    }

    public struct CacheOperationFailure: Error, Sendable, Equatable, LocalizedError {
        public let operation: CacheOperation
        public let path: String
        public let reason: String

        public var errorDescription: String? {
            "\(operation.rawValue) failed for \(path): \(reason)"
        }
    }

    public struct CacheUsageSnapshot: Sendable, Equatable {
        public let totalBytes: Int64
        public let fileCount: Int

        public init(totalBytes: Int64, fileCount: Int) {
            self.totalBytes = totalBytes
            self.fileCount = fileCount
        }
    }

    public struct CacheClearResult: Sendable, Equatable {
        public let clearedBytes: Int64
        public let removedItemCount: Int
        public let failures: [CacheOperationFailure]

        public init(clearedBytes: Int64, removedItemCount: Int, failures: [CacheOperationFailure] = []) {
            self.clearedBytes = clearedBytes
            self.removedItemCount = removedItemCount
            self.failures = failures
        }
    }

    public enum ApplicationCacheServiceError: Error, Sendable, Equatable, LocalizedError {
        case noCacheDirectories
        case scanFailed([CacheOperationFailure])
        case clearFailed(CacheClearResult)

        public var errorDescription: String? {
            switch self {
            case .noCacheDirectories:
                return "No user cache directories are available."
            case .scanFailed(let failures):
                return "Cache size scan failed with \(failures.count) error(s)."
            case .clearFailed(let result):
                return "Cache clear failed with \(result.failures.count) error(s)."
            }
        }
    }

    private struct DirectoryScanResult: Sendable {
        var totalBytes: Int64 = 0
        var fileCount: Int = 0
        var failures: [CacheOperationFailure] = []

        mutating func merge(_ other: DirectoryScanResult) {
            totalBytes += other.totalBytes
            fileCount += other.fileCount
            failures.append(contentsOf: other.failures)
        }
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey
    ]

    private let cacheDirectories: [URL]

    public init(cacheDirectories: [URL]? = nil) {
        let directories = cacheDirectories ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        self.cacheDirectories = directories.map { $0.standardizedFileURL }
    }

    public func cacheUsageSnapshot() throws -> CacheUsageSnapshot {
        guard !cacheDirectories.isEmpty else {
            throw ApplicationCacheServiceError.noCacheDirectories
        }

        let fileManager = FileManager.default
        var aggregate = DirectoryScanResult()

        for directory in cacheDirectories {
            do {
                guard let existingDirectory = try existingCacheDirectory(
                    directory,
                    operation: .measure,
                    fileManager: fileManager
                ) else {
                    continue
                }

                aggregate.merge(scanDirectory(existingDirectory, fileManager: fileManager))
            } catch let failure as CacheOperationFailure {
                aggregate.failures.append(failure)
            } catch {
                aggregate.failures.append(
                    CacheOperationFailure(
                        operation: .measure,
                        path: directory.path,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        guard aggregate.failures.isEmpty else {
            throw ApplicationCacheServiceError.scanFailed(aggregate.failures)
        }

        return CacheUsageSnapshot(totalBytes: aggregate.totalBytes, fileCount: aggregate.fileCount)
    }

    public func clearCaches() throws -> CacheClearResult {
        guard !cacheDirectories.isEmpty else {
            throw ApplicationCacheServiceError.noCacheDirectories
        }

        let fileManager = FileManager.default
        var clearedBytes: Int64 = 0
        var removedItemCount = 0
        var failures: [CacheOperationFailure] = []

        for directory in cacheDirectories {
            do {
                guard let existingDirectory = try existingCacheDirectory(
                    directory,
                    operation: .clear,
                    fileManager: fileManager
                ) else {
                    continue
                }

                let children = try fileManager.contentsOfDirectory(
                    at: existingDirectory,
                    includingPropertiesForKeys: Array(Self.resourceKeys),
                    options: []
                )

                for child in children {
                    let scanResult = scanItem(child, fileManager: fileManager)
                    failures.append(contentsOf: scanResult.failures)

                    do {
                        try fileManager.removeItem(at: child)
                        clearedBytes += scanResult.totalBytes
                        removedItemCount += 1
                    } catch {
                        failures.append(
                            CacheOperationFailure(
                                operation: .clear,
                                path: child.path,
                                reason: error.localizedDescription
                            )
                        )
                    }
                }
            } catch let failure as CacheOperationFailure {
                failures.append(failure)
            } catch {
                failures.append(
                    CacheOperationFailure(
                        operation: .clear,
                        path: directory.path,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        let result = CacheClearResult(
            clearedBytes: clearedBytes,
            removedItemCount: removedItemCount,
            failures: failures
        )

        guard failures.isEmpty else {
            throw ApplicationCacheServiceError.clearFailed(result)
        }

        return result
    }

    private func existingCacheDirectory(
        _ directory: URL,
        operation: CacheOperation,
        fileManager: FileManager
    ) throws -> URL? {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return nil
        }

        guard isDirectory.boolValue else {
            throw CacheOperationFailure(
                operation: operation,
                path: directory.path,
                reason: "Expected a cache directory but found a file."
            )
        }

        return directory
    }

    private func scanDirectory(_ directory: URL, fileManager: FileManager) -> DirectoryScanResult {
        do {
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: []
            )
            return children.reduce(into: DirectoryScanResult()) { partialResult, child in
                partialResult.merge(scanItem(child, fileManager: fileManager))
            }
        } catch {
            return DirectoryScanResult(
                failures: [
                    CacheOperationFailure(
                        operation: .measure,
                        path: directory.path,
                        reason: error.localizedDescription
                    )
                ]
            )
        }
    }

    private func scanItem(_ item: URL, fileManager: FileManager) -> DirectoryScanResult {
        do {
            let resourceValues = try item.resourceValues(forKeys: Self.resourceKeys)

            if resourceValues.isSymbolicLink == true {
                return DirectoryScanResult()
            }

            if resourceValues.isDirectory == true {
                return scanDirectory(item, fileManager: fileManager)
            }

            guard resourceValues.isRegularFile == true else {
                return DirectoryScanResult()
            }

            let byteCount = resourceValues.fileSize
                ?? resourceValues.totalFileAllocatedSize
                ?? resourceValues.fileAllocatedSize
                ?? 0

            return DirectoryScanResult(totalBytes: Int64(byteCount), fileCount: 1)
        } catch {
            return DirectoryScanResult(
                failures: [
                    CacheOperationFailure(
                        operation: .measure,
                        path: item.path,
                        reason: error.localizedDescription
                    )
                ]
            )
        }
    }
}
