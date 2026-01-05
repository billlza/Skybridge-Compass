// MARK: - ScanErrorSanitizer.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// Sanitizes scan errors for safe output.
///
/// Uses PathSanitizer to ensure no absolute paths are exposed in
/// user-visible error messages. Logs may include full paths only in DEBUG.
///
/// **Requirements: 12.6** - Sanitized error details
public struct ScanErrorSanitizer: Sendable {
    
 // MARK: - User-Visible Error Messages
    
 /// Sanitize a FileScanError for user-visible output.
 ///
 /// Removes absolute paths and sensitive information from error messages.
 ///
 /// - Parameter error: The FileScanError to sanitize
 /// - Returns: Sanitized error message safe for user display
 ///
 /// **Requirements: 12.6**
    public static func sanitize(_ error: FileScanError) -> String {
        switch error {
        case .fileNotFound(let url):
            return "File not found: \(PathSanitizer.sanitize(url))"
            
        case .permissionDenied(let url):
            return "Permission denied: \(PathSanitizer.sanitize(url))"
            
        case .timeout(let url, let duration):
            return "Scan timeout after \(String(format: "%.1f", duration))s: \(PathSanitizer.sanitize(url))"
            
        case .cancelled:
            return "Scan was cancelled"
            
        case .commandFailed(let command, let exitCode, _):
 // Don't expose stderr in user-visible output
            return "Command '\(sanitizeCommand(command))' failed with exit code \(exitCode)"
            
        case .invalidFileType(let url):
            return "Invalid file type: \(PathSanitizer.sanitize(url))"
            
        case .resourceExhausted:
            return "System resources exhausted"
            
        case .archiveLimitExceeded(let reason):
            return "Archive limit exceeded: \(reason)"
            
        case .symlinkDepthExceeded(let url, let depth):
            return "Symbolic link depth exceeded (\(depth)): \(PathSanitizer.sanitize(url))"
            
        case .fileBeingWritten(let url):
            return "File is being written: \(PathSanitizer.sanitize(url))"
            
        case .unknown(let message):
 // Sanitize any paths that might be in the message
            return "Error: \(sanitizeMessage(message))"
        }
    }
    
 /// Sanitize a StreamingHashError for user-visible output.
 ///
 /// - Parameter error: The StreamingHashError to sanitize
 /// - Returns: Sanitized error message safe for user display
    public static func sanitize(_ error: StreamingHashError) -> String {
        switch error {
        case .fileNotFound(let url):
            return "File not found: \(PathSanitizer.sanitize(url))"
            
        case .permissionDenied(let url):
            return "Permission denied: \(PathSanitizer.sanitize(url))"
            
        case .readError(let message):
            return "Read error: \(sanitizeMessage(message))"
            
        case .cancelled:
            return "Operation was cancelled"
        }
    }
    
 /// Sanitize any Error for user-visible output.
 ///
 /// - Parameters:
 /// - error: The error to sanitize
 /// - url: Optional URL associated with the error
 /// - Returns: Sanitized error message safe for user display
    public static func sanitize(_ error: Error, url: URL? = nil) -> String {
        if let scanError = error as? FileScanError {
            return sanitize(scanError)
        }
        
        if let hashError = error as? StreamingHashError {
            return sanitize(hashError)
        }
        
 // Generic error handling
        let message = sanitizeMessage(error.localizedDescription)
        if let url = url {
            return "\(PathSanitizer.sanitize(url)): \(message)"
        }
        return message
    }
    
 // MARK: - Log-Safe Error Messages
    
 /// Sanitize a FileScanError for log output.
 ///
 /// In DEBUG, includes full paths. In RELEASE, uses hash+extension format.
 ///
 /// - Parameter error: The FileScanError to sanitize
 /// - Returns: Sanitized error message appropriate for logging
 ///
 /// **Requirements: 12.6**
    public static func sanitizeForLog(_ error: FileScanError) -> String {
        switch error {
        case .fileNotFound(let url):
            return "File not found: \(PathSanitizer.sanitizeForLog(url))"
            
        case .permissionDenied(let url):
            return "Permission denied: \(PathSanitizer.sanitizeForLog(url))"
            
        case .timeout(let url, let duration):
            return "Scan timeout after \(String(format: "%.1f", duration))s: \(PathSanitizer.sanitizeForLog(url))"
            
        case .cancelled:
            return "Scan was cancelled"
            
        case .commandFailed(let command, let exitCode, let stderr):
            #if DEBUG
            return "Command '\(command)' failed with exit code \(exitCode): \(stderr)"
            #else
            return "Command '\(sanitizeCommand(command))' failed with exit code \(exitCode)"
            #endif
            
        case .invalidFileType(let url):
            return "Invalid file type: \(PathSanitizer.sanitizeForLog(url))"
            
        case .resourceExhausted:
            return "System resources exhausted"
            
        case .archiveLimitExceeded(let reason):
            return "Archive limit exceeded: \(reason)"
            
        case .symlinkDepthExceeded(let url, let depth):
            return "Symbolic link depth exceeded (\(depth)): \(PathSanitizer.sanitizeForLog(url))"
            
        case .fileBeingWritten(let url):
            return "File is being written: \(PathSanitizer.sanitizeForLog(url))"
            
        case .unknown(let message):
            #if DEBUG
            return "Unknown error: \(message)"
            #else
            return "Unknown error: \(sanitizeMessage(message))"
            #endif
        }
    }
    
 /// Sanitize any Error for log output.
 ///
 /// - Parameters:
 /// - error: The error to sanitize
 /// - url: Optional URL associated with the error
 /// - Returns: Sanitized error message appropriate for logging
    public static func sanitizeForLog(_ error: Error, url: URL? = nil) -> String {
        if let scanError = error as? FileScanError {
            return sanitizeForLog(scanError)
        }
        
        #if DEBUG
        let message = error.localizedDescription
        #else
        let message = sanitizeMessage(error.localizedDescription)
        #endif
        
        if let url = url {
            return "\(PathSanitizer.sanitizeForLog(url)): \(message)"
        }
        return message
    }
    
 // MARK: - Private Helpers
    
 /// Sanitize a command string (remove paths).
    private static func sanitizeCommand(_ command: String) -> String {
 // Extract just the command name, not full path
        let components = command.components(separatedBy: " ")
        guard let firstComponent = components.first else { return command }
        
 // Get basename of command
        let commandName = (firstComponent as NSString).lastPathComponent
        
 // Reconstruct with sanitized command name
        if components.count > 1 {
            return commandName + " ..."
        }
        return commandName
    }
    
 /// Sanitize a message that might contain paths.
 ///
 /// Attempts to detect and sanitize path-like strings in the message.
    private static func sanitizeMessage(_ message: String) -> String {
 // Simple heuristic: replace anything that looks like an absolute path
        var result = message
        
 // Pattern for absolute paths (Unix-style)
        let pathPattern = #"/(?:Users|home|var|tmp|private|Volumes)/[^\s\"\'<>|]+"#
        
        if let regex = try? NSRegularExpression(pattern: pathPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range)
            
 // Replace matches in reverse order to preserve indices
            for match in matches.reversed() {
                if let swiftRange = Range(match.range, in: result) {
                    let path = String(result[swiftRange])
                    let sanitized = PathSanitizer.sanitize(path)
                    result.replaceSubrange(swiftRange, with: sanitized)
                }
            }
        }
        
        return result
    }
}

// MARK: - ScanWarning Extension

extension ScanWarning {
 /// Create a sanitized warning from an error.
 ///
 /// - Parameters:
 /// - error: The error to convert
 /// - severity: Warning severity
 /// - Returns: ScanWarning with sanitized message
    public static func fromError(
        _ error: Error,
        severity: Severity = .warning
    ) -> ScanWarning {
        let sanitizedMessage = ScanErrorSanitizer.sanitize(error)
        
        let code: String
        if let scanError = error as? FileScanError {
            code = scanError.code
        } else if let hashError = error as? StreamingHashError {
            switch hashError {
            case .fileNotFound: code = "FILE_NOT_FOUND"
            case .permissionDenied: code = "PERMISSION_DENIED"
            case .readError: code = "READ_ERROR"
            case .cancelled: code = "CANCELLED"
            }
        } else {
            code = "UNKNOWN_ERROR"
        }
        
        return ScanWarning(
            code: code,
            message: sanitizedMessage,
            severity: severity
        )
    }
}
