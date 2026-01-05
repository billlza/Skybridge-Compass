// MARK: - StreamingHasher.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation
import CryptoKit

/// Result of a streaming hash operation.
public struct StreamingHashResult: Sendable {
 /// The computed hash (SHA256 hex string), or partial hash if timed out
    public let hash: String
    
 /// Whether the hash is complete (false if timed out)
    public let isComplete: Bool
    
 /// Number of bytes hashed
    public let bytesHashed: Int64
    
 /// Total file size (if known)
    public let totalBytes: Int64?
    
 /// Duration of the hash operation
    public let duration: TimeInterval
    
 /// Error if hash failed (not timeout)
    public let error: StreamingHashError?
    
    public init(
        hash: String,
        isComplete: Bool,
        bytesHashed: Int64,
        totalBytes: Int64? = nil,
        duration: TimeInterval,
        error: StreamingHashError? = nil
    ) {
        self.hash = hash
        self.isComplete = isComplete
        self.bytesHashed = bytesHashed
        self.totalBytes = totalBytes
        self.duration = duration
        self.error = error
    }
}

/// Errors that can occur during streaming hash.
public enum StreamingHashError: Error, Sendable {
    case fileNotFound(URL)
    case permissionDenied(URL)
    case readError(String)
    case cancelled
    
    public var localizedDescription: String {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(PathSanitizer.sanitize(url))"
        case .permissionDenied(let url):
            return "Permission denied: \(PathSanitizer.sanitize(url))"
        case .readError(let message):
            return "Read error: \(message)"
        case .cancelled:
            return "Hash operation was cancelled"
        }
    }
}

/// Streaming file hasher with timeout support.
///
/// Computes SHA256 hash of a file using streaming reads to avoid
/// loading the entire file into memory. Supports timeout to prevent
/// DoS attacks with large or slow files.
///
/// **Requirements: 12.1, 12.5**
/// - Per-file timeout based on scan level
/// - Return partial hash on timeout, not block entire scan
public actor StreamingHasher {
    
 /// Buffer size for streaming reads (64KB)
    private let bufferSize: Int = 64 * 1024
    
 /// Clock for timeout tracking
    private let clock = ContinuousClock()
    
 // MARK: - Public API
    
 /// Compute SHA256 hash of a file with timeout.
 ///
 /// - Parameters:
 /// - url: File URL to hash
 /// - timeout: Maximum time allowed for hashing
 /// - Returns: StreamingHashResult with hash and completion status
 ///
 /// **Requirements: 12.1, 12.5**
    public func hash(
        url: URL,
        timeout: TimeInterval
    ) async -> StreamingHashResult {
        let startTime = clock.now
        let deadline = startTime.advanced(by: .seconds(timeout))
        
 // Get file size
        let fileSize: Int64?
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = attrs[.size] as? Int64
        } catch {
            fileSize = nil
        }
        
 // Open file handle
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch let error as NSError {
            let duration = clock.now.duration(to: startTime).asTimeInterval
            
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                    return StreamingHashResult(
                        hash: "",
                        isComplete: false,
                        bytesHashed: 0,
                        totalBytes: fileSize,
                        duration: abs(duration),
                        error: .fileNotFound(url)
                    )
                case NSFileReadNoPermissionError:
                    return StreamingHashResult(
                        hash: "",
                        isComplete: false,
                        bytesHashed: 0,
                        totalBytes: fileSize,
                        duration: abs(duration),
                        error: .permissionDenied(url)
                    )
                default:
                    break
                }
            }
            
            return StreamingHashResult(
                hash: "",
                isComplete: false,
                bytesHashed: 0,
                totalBytes: fileSize,
                duration: abs(duration),
                error: .readError(error.localizedDescription)
            )
        }
        
        defer { try? handle.close() }
        
 // Stream and hash
        var hasher = SHA256()
        var bytesHashed: Int64 = 0
        var isComplete = false
        var hashError: StreamingHashError? = nil
        
        do {
            while true {
 // Check for cancellation
                if Task.isCancelled {
                    hashError = .cancelled
                    break
                }
                
 // Check timeout
                if clock.now >= deadline {
 // Timeout - return partial hash
                    break
                }
                
 // Read next chunk
                let data = handle.readData(ofLength: bufferSize)
                
                if data.isEmpty {
 // EOF - hash is complete
                    isComplete = true
                    break
                }
                
 // Update hash
                hasher.update(data: data)
                bytesHashed += Int64(data.count)
            }
        }
        
 // Finalize hash
        let digest = hasher.finalize()
        let hashString = digest.compactMap { String(format: "%02x", $0) }.joined()
        
        let endTime = clock.now
        let duration = startTime.duration(to: endTime).asTimeInterval
        
        return StreamingHashResult(
            hash: hashString,
            isComplete: isComplete,
            bytesHashed: bytesHashed,
            totalBytes: fileSize,
            duration: duration,
            error: hashError
        )
    }
    
 /// Compute SHA256 hash using ScanPolicy timeout.
 ///
 /// - Parameters:
 /// - url: File URL to hash
 /// - policy: ScanPolicy containing timeout configuration
 /// - Returns: StreamingHashResult with hash and completion status
 ///
 /// **Requirements: 12.1**
    public func hash(
        url: URL,
        policy: ScanPolicy
    ) async -> StreamingHashResult {
        await hash(url: url, timeout: policy.hashTimeout)
    }
}

// MARK: - Duration Extension

private extension Duration {
 /// Convert Duration to TimeInterval (seconds)
    var asTimeInterval: TimeInterval {
        let (seconds, attoseconds) = self.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1_000_000_000_000_000_000
    }
}
