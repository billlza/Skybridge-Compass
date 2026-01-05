// MARK: - LargeFileProcessor.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// Classification of files by size for processing strategy.
public enum FileSizeClass: Sendable {
 /// Normal file - can be processed concurrently
    case normal
 /// Large file - must be processed sequentially to prevent memory exhaustion
    case large
    
 /// Determine size class based on file size and threshold.
 ///
 /// - Parameters:
 /// - fileSize: Size of the file in bytes
 /// - threshold: Large file threshold (default from SecurityLimits)
 /// - Returns: FileSizeClass indicating processing strategy
    public static func classify(
        fileSize: Int64,
        threshold: Int64 = SecurityLimits.default.largeFileThreshold
    ) -> FileSizeClass {
        fileSize > threshold ? .large : .normal
    }
}

/// Result of file classification for batch processing.
public struct FileClassification: Sendable {
 /// URL of the file
    public let url: URL
 /// Size of the file in bytes
    public let size: Int64
 /// Size classification
    public let sizeClass: FileSizeClass
 /// Whether file is accessible
    public let isAccessible: Bool
 /// Error if file is not accessible
    public let error: Error?
    
    public init(
        url: URL,
        size: Int64,
        sizeClass: FileSizeClass,
        isAccessible: Bool,
        error: Error? = nil
    ) {
        self.url = url
        self.size = size
        self.sizeClass = sizeClass
        self.isAccessible = isAccessible
        self.error = error
    }
}

/// Processor for handling large files sequentially to prevent memory exhaustion.
///
/// Large files (exceeding largeFileThreshold) are processed one at a time
/// to avoid concurrent memory pressure. Normal files can be processed
/// concurrently up to the configured limit.
///
/// **Requirements: 12.4** - Large file sequential processing
public actor LargeFileProcessor {
    
 /// Security limits configuration
    private let limits: SecurityLimits
    
 /// Large file threshold in bytes
    public var largeFileThreshold: Int64 {
        limits.largeFileThreshold
    }
    
 // MARK: - Initialization
    
 /// Creates a LargeFileProcessor with the specified limits.
 ///
 /// - Parameter limits: Security limits configuration
    public init(limits: SecurityLimits = .default) {
        self.limits = limits
    }
    
 // MARK: - File Classification
    
 /// Classify a single file by size.
 ///
 /// - Parameter url: File URL to classify
 /// - Returns: FileClassification with size and accessibility info
    public func classify(url: URL) -> FileClassification {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int64) ?? 0
            let sizeClass = FileSizeClass.classify(fileSize: size, threshold: largeFileThreshold)
            
            return FileClassification(
                url: url,
                size: size,
                sizeClass: sizeClass,
                isAccessible: true,
                error: nil
            )
        } catch {
            return FileClassification(
                url: url,
                size: 0,
                sizeClass: .normal,
                isAccessible: false,
                error: error
            )
        }
    }
    
 /// Classify multiple files by size.
 ///
 /// - Parameter urls: File URLs to classify
 /// - Returns: Array of FileClassification results
    public func classify(urls: [URL]) -> [FileClassification] {
        urls.map { classify(url: $0) }
    }
    
 /// Partition files into normal and large categories.
 ///
 /// - Parameter urls: File URLs to partition
 /// - Returns: Tuple of (normalFiles, largeFiles)
 ///
 /// **Requirements: 12.4**
    public func partition(urls: [URL]) -> (normal: [URL], large: [URL]) {
        var normal: [URL] = []
        var large: [URL] = []
        
        for url in urls {
            let classification = classify(url: url)
            
 // Skip inaccessible files (they'll be handled as errors later)
            guard classification.isAccessible else {
                normal.append(url)  // Let error handling deal with it
                continue
            }
            
            switch classification.sizeClass {
            case .normal:
                normal.append(url)
            case .large:
                large.append(url)
            }
        }
        
        return (normal, large)
    }
    
 // MARK: - Sequential Processing
    
 /// Process files with appropriate concurrency based on size.
 ///
 /// Normal files are processed concurrently (up to maxConcurrent).
 /// Large files are processed sequentially (one at a time).
 ///
 /// - Parameters:
 /// - urls: File URLs to process
 /// - maxConcurrent: Maximum concurrent operations for normal files
 /// - operation: Async operation to perform on each file
 /// - Returns: Array of results in input order
 ///
 /// **Requirements: 12.4**
    public func process<T: Sendable>(
        urls: [URL],
        maxConcurrent: Int = 4,
        operation: @escaping @Sendable (URL) async -> T
    ) async -> [T] {
 // Partition files
        let (normalURLs, largeURLs) = partition(urls: urls)
        
 // Create result storage with index mapping
        var results: [Int: T] = [:]
        let urlToIndex = Dictionary(uniqueKeysWithValues: urls.enumerated().map { ($0.element, $0.offset) })
        
 // Process normal files concurrently
        await withTaskGroup(of: (Int, T).self) { group in
            var activeCount = 0
            var pendingNormal = normalURLs.makeIterator()
            
 // Start initial batch
            while activeCount < maxConcurrent, let url = pendingNormal.next() {
                activeCount += 1
                let index = urlToIndex[url]!
                group.addTask {
                    let result = await operation(url)
                    return (index, result)
                }
            }
            
 // Process remaining normal files
            for await (index, result) in group {
                results[index] = result
                activeCount -= 1
                
                if let url = pendingNormal.next() {
                    activeCount += 1
                    let nextIndex = urlToIndex[url]!
                    group.addTask {
                        let result = await operation(url)
                        return (nextIndex, result)
                    }
                }
            }
        }
        
 // Process large files sequentially (one at a time)
        for url in largeURLs {
            let index = urlToIndex[url]!
            let result = await operation(url)
            results[index] = result
        }
        
 // Return results in original order
        return urls.indices.compactMap { results[$0] }
    }
    
 // MARK: - Statistics
    
 /// Get statistics about file sizes in a batch.
 ///
 /// - Parameter urls: File URLs to analyze
 /// - Returns: Statistics about the batch
    public func statistics(for urls: [URL]) -> BatchStatistics {
        let classifications = classify(urls: urls)
        
        let totalSize = classifications.reduce(Int64(0)) { $0 + $1.size }
        let normalCount = classifications.filter { $0.sizeClass == .normal && $0.isAccessible }.count
        let largeCount = classifications.filter { $0.sizeClass == .large && $0.isAccessible }.count
        let inaccessibleCount = classifications.filter { !$0.isAccessible }.count
        let largestFile = classifications.max(by: { $0.size < $1.size })
        
        return BatchStatistics(
            totalFiles: urls.count,
            totalSize: totalSize,
            normalFileCount: normalCount,
            largeFileCount: largeCount,
            inaccessibleCount: inaccessibleCount,
            largestFileSize: largestFile?.size ?? 0,
            largestFileURL: largestFile?.url
        )
    }
}

// MARK: - BatchStatistics

/// Statistics about a batch of files.
public struct BatchStatistics: Sendable {
 /// Total number of files
    public let totalFiles: Int
 /// Total size of all files in bytes
    public let totalSize: Int64
 /// Number of normal-sized files
    public let normalFileCount: Int
 /// Number of large files
    public let largeFileCount: Int
 /// Number of inaccessible files
    public let inaccessibleCount: Int
 /// Size of the largest file
    public let largestFileSize: Int64
 /// URL of the largest file
    public let largestFileURL: URL?
    
 /// Whether any large files are present
    public var hasLargeFiles: Bool {
        largeFileCount > 0
    }
    
 /// Percentage of files that are large
    public var largeFilePercentage: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(largeFileCount) / Double(totalFiles) * 100
    }
}

// MARK: - BatchStatistics + Description

extension BatchStatistics: CustomStringConvertible {
    public var description: String {
        """
        BatchStatistics:
          totalFiles: \(totalFiles)
          totalSize: \(totalSize / 1024 / 1024)MB
          normalFiles: \(normalFileCount)
          largeFiles: \(largeFileCount)
          inaccessible: \(inaccessibleCount)
          largestFile: \(largestFileSize / 1024 / 1024)MB
        """
    }
}
