// MARK: - PathSanitizer.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation
import CryptoKit

/// Path sanitization utility for security-conscious output.
///
/// Provides methods to sanitize file paths for different contexts:
/// - User-visible output: Returns basename only (no directory info)
/// - Log output: DEBUG shows full path, RELEASE shows extension + hash prefix
///
/// This prevents leaking sensitive path information in user-facing messages
/// while maintaining debuggability in development builds.
///
/// **Requirements: 12.6** - Sanitized error details (no absolute paths in user-visible output)
internal struct PathSanitizer: Sendable {
    
 // MARK: - User-Visible Output
    
 /// Sanitize path for user-visible output.
 ///
 /// Returns only the basename (last path component) to prevent
 /// exposing directory structure to users.
 ///
 /// - Parameter url: The file URL to sanitize
 /// - Returns: The basename of the file (e.g., "document.pdf")
 ///
 /// **Requirements: 12.6**
    static func sanitize(_ url: URL) -> String {
        return url.lastPathComponent
    }
    
 /// Sanitize path string for user-visible output.
 ///
 /// - Parameter path: The file path string to sanitize
 /// - Returns: The basename of the file
    static func sanitize(_ path: String) -> String {
        return (path as NSString).lastPathComponent
    }
    
 // MARK: - Log Output
    
 /// Sanitize path for log output with DEBUG/RELEASE difference.
 ///
 /// - DEBUG: Returns full path for debugging
 /// - RELEASE: Returns extension + hash prefix (8 hex chars) for privacy
 ///
 /// - Parameter url: The file URL to sanitize
 /// - Returns: Sanitized path string appropriate for current build
 ///
 /// **Requirements: 12.6**
    static func sanitizeForLog(_ url: URL) -> String {
        return sanitizeForLog(url.path)
    }
    
 /// Sanitize path string for log output with DEBUG/RELEASE difference.
 ///
 /// - DEBUG: Returns full path for debugging
 /// - RELEASE: Returns extension + hash prefix (8 hex chars) for privacy
 ///
 /// - Parameter path: The file path string to sanitize
 /// - Returns: Sanitized path string appropriate for current build
    static func sanitizeForLog(_ path: String) -> String {
        #if DEBUG
        return path
        #else
        return sanitizePathForRelease(path)
        #endif
    }
    
 // MARK: - Error Sanitization
    
 /// Sanitize error details for user-visible output.
 ///
 /// Combines sanitized path with error description.
 ///
 /// - Parameters:
 /// - error: The error that occurred
 /// - url: The file URL associated with the error
 /// - Returns: Sanitized error message
    static func sanitizeError(_ error: Error, url: URL) -> String {
        let sanitizedPath = sanitize(url)
        return "\(sanitizedPath): \(error.localizedDescription)"
    }
    
 /// Sanitize error details for user-visible output.
 ///
 /// - Parameters:
 /// - error: The error that occurred
 /// - path: The file path associated with the error
 /// - Returns: Sanitized error message
    static func sanitizeError(_ error: Error, path: String) -> String {
        let sanitizedPath = sanitize(path)
        return "\(sanitizedPath): \(error.localizedDescription)"
    }
    
 // MARK: - Private Helpers
    
 /// Sanitize path for RELEASE builds: extension + hash prefix.
 ///
 /// Format: "<8-char-hash><.extension>" or "<8-char-hash>" if no extension
 /// Example: "a1b2c3d4.pdf" or "a1b2c3d4"
    private static func sanitizePathForRelease(_ path: String) -> String {
        let nsPath = path as NSString
        let ext = nsPath.pathExtension
        let hashPrefix = computeHashPrefix(path)
        
        if ext.isEmpty {
            return hashPrefix
        } else {
            return "\(hashPrefix).\(ext)"
        }
    }
    
 /// Compute SHA256 hash prefix (first 8 hex characters) of the path.
    private static func computeHashPrefix(_ path: String) -> String {
        guard let data = path.data(using: .utf8) else {
            return "unknown"
        }
        
        let hash = SHA256.hash(data: data)
 // Take first 4 bytes (8 hex characters)
        let prefix = hash.prefix(4)
        return prefix.map { String(format: "%02x", $0) }.joined()
    }
}
