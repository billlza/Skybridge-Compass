// MARK: - SymlinkResolver.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// Result of symlink resolution with security checks.
public struct SymlinkResolutionResult: Sendable {
 /// The resolved canonical URL (nil if resolution failed)
    public let resolvedURL: URL?
    
 /// The actual chain depth traversed during resolution
    public let chainDepth: Int
    
 /// Error if resolution failed
    public let error: ResolutionError?
    
 /// Whether resolution was successful
    public var isSuccess: Bool { resolvedURL != nil && error == nil }
    
 /// Resolution error types
    public enum ResolutionError: String, Sendable, Equatable {
 /// realpath() or readlink() failed
        case realpathFailed
 /// Resolved path is outside the allowed scan root
        case outsideScanRoot
 /// Symlink chain depth exceeded maxSymlinkDepth
        case depthExceeded
 /// Circular symlink detected (path visited twice)
        case circularLink
 /// File is inaccessible (permission denied or not found)
        case inaccessible
    }
    
    public init(resolvedURL: URL?, chainDepth: Int, error: ResolutionError?) {
        self.resolvedURL = resolvedURL
        self.chainDepth = chainDepth
        self.error = error
    }
    
 /// Create a successful result
    public static func success(resolvedURL: URL, chainDepth: Int) -> SymlinkResolutionResult {
        SymlinkResolutionResult(resolvedURL: resolvedURL, chainDepth: chainDepth, error: nil)
    }
    
 /// Create a failed result
    public static func failure(error: ResolutionError, chainDepth: Int = 0) -> SymlinkResolutionResult {
        SymlinkResolutionResult(resolvedURL: nil, chainDepth: chainDepth, error: error)
    }
}

/// Secure symlink resolver with depth limiting and cycle detection.
///
/// Key security features:
/// - Manual iteration using lstat()/readlink() for precise depth tracking
/// - Cycle detection via visited path set
/// - Scan root boundary enforcement
/// - Final realpath() for canonical path
///
/// **Why manual iteration instead of just realpath()**:
/// - realpath() only returns success/failure, no chain depth info
/// - ELOOP error can't distinguish "system limit" vs "our maxSymlinkDepth"
/// - Can't report exactly which depth caused failure
public struct SymlinkResolver: Sendable {
    
 /// Security limits configuration
    private let limits: SecurityLimits
    
 /// Initialize with security limits
    public init(limits: SecurityLimits = .default) {
        self.limits = limits
    }
    
 /// Resolve a symbolic link with security checks.
 ///
 /// Resolution strategy (must use manual iteration):
 /// 1. Use lstat() to detect if path is a symlink
 /// 2. If symlink, use readlink() to get target
 /// 3. Iterate, tracking chainDepth and visitedPaths
 /// 4. Loop termination conditions:
 /// - lstat shows not a symlink (reached final target)
 /// - chainDepth > maxSymlinkDepth → .depthExceeded
 /// - Path in visitedPaths → .circularLink
 /// - readlink/lstat fails → .realpathFailed
 /// 5. Final realpath() for canonical path
 /// 6. Check canonical path is within scanRoot
 ///
 /// - Parameters:
 /// - url: The URL to resolve
 /// - scanRoot: The allowed scan root directory
 /// - Returns: Resolution result with canonical URL or error
    public func resolve(url: URL, scanRoot: URL) -> SymlinkResolutionResult {
        let path = url.path
        
 // Check if file/symlink exists using lstat (doesn't follow symlinks)
 // This allows us to detect circular symlinks properly
        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else {
            return .failure(error: .inaccessible, chainDepth: 0)
        }
        
 // Manual iteration to resolve symlinks
        let (resolvedPath, chainDepth, iterationError) = iterativeResolve(path)
        
        if let error = iterationError {
            return .failure(error: error, chainDepth: chainDepth)
        }
        
        guard let resolved = resolvedPath else {
            return .failure(error: .realpathFailed, chainDepth: chainDepth)
        }
        
 // Get canonical path using realpath()
        guard let canonicalPath = callRealpath(resolved) else {
            return .failure(error: .realpathFailed, chainDepth: chainDepth)
        }
        
        let canonicalURL = URL(fileURLWithPath: canonicalPath)
        
 // Check if resolved path is within scan root
        if !isWithinScanRoot(canonicalURL, root: scanRoot) {
            return .failure(error: .outsideScanRoot, chainDepth: chainDepth)
        }
        
        return .success(resolvedURL: canonicalURL, chainDepth: chainDepth)
    }
    
 /// Resolve symlink without scan root check (for single file scans).
 /// Uses the file's parent directory as implicit scan root.
 ///
 /// - Parameter url: The URL to resolve
 /// - Returns: Resolution result with canonical URL or error
    public func resolve(url: URL) -> SymlinkResolutionResult {
        let scanRoot = url.deletingLastPathComponent()
        return resolve(url: url, scanRoot: scanRoot)
    }
    
 // MARK: - Private Methods
    
 /// Manual iterative symlink resolution.
 ///
 /// - Parameter path: The path to resolve
 /// - Returns: Tuple of (resolvedPath, chainDepth, error)
    private func iterativeResolve(_ path: String) -> (String?, Int, SymlinkResolutionResult.ResolutionError?) {
        var currentPath = path
        var chainDepth = 0
        var visitedPaths = Set<String>()
        
        while true {
 // Check for circular link
            if visitedPaths.contains(currentPath) {
                return (nil, chainDepth, .circularLink)
            }
            visitedPaths.insert(currentPath)
            
 // Check if current path is a symlink
            guard isSymlink(currentPath) else {
 // Not a symlink - we've reached the final target
                return (currentPath, chainDepth, nil)
            }
            
 // Check depth limit before following
            if chainDepth >= limits.maxSymlinkDepth {
                return (nil, chainDepth, .depthExceeded)
            }
            
 // Read symlink target
            guard let target = readSymlink(currentPath) else {
                return (nil, chainDepth, .realpathFailed)
            }
            
 // Increment depth after successful readlink
            chainDepth += 1
            
 // Resolve relative symlinks
            if target.hasPrefix("/") {
                currentPath = target
            } else {
 // Relative path - resolve against parent directory
                let parentDir = (currentPath as NSString).deletingLastPathComponent
                currentPath = (parentDir as NSString).appendingPathComponent(target)
            }
            
 // Normalize path (remove . and ..)
            currentPath = (currentPath as NSString).standardizingPath
        }
    }
    
 /// Check if path is a symbolic link using lstat().
 ///
 /// - Parameter path: The path to check
 /// - Returns: true if path is a symlink
    private func isSymlink(_ path: String) -> Bool {
        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else {
            return false
        }
        return (statBuf.st_mode & S_IFMT) == S_IFLNK
    }
    
 /// Read symlink target using readlink().
 ///
 /// - Parameter path: The symlink path
 /// - Returns: The target path, or nil if failed
    private func readSymlink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = readlink(path, &buffer, Int(PATH_MAX) - 1)
        guard length > 0 else {
            return nil
        }
 // Convert to String using modern API (truncate at length)
        let data = buffer.prefix(length).map { UInt8(bitPattern: $0) }
        return String(decoding: data, as: UTF8.self)
    }
    
 /// Get canonical path using realpath().
 ///
 /// - Parameter path: The path to canonicalize
 /// - Returns: The canonical path, or nil if failed
    private func callRealpath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    
 /// Check if resolved URL is within the scan root.
 ///
 /// - Parameters:
 /// - resolved: The resolved URL
 /// - root: The scan root URL
 /// - Returns: true if resolved is within root
    private func isWithinScanRoot(_ resolved: URL, root: URL) -> Bool {
        let resolvedPath = resolved.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        
 // Ensure root path ends with / for proper prefix matching
        let normalizedRoot = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        
 // Check if resolved path starts with root path or equals root path
        return resolvedPath == rootPath || resolvedPath.hasPrefix(normalizedRoot)
    }
}

// MARK: - Testing Support

#if DEBUG
extension SymlinkResolver {
 /// Create a resolver with custom limits for testing
    public static func createForTesting(maxSymlinkDepth: Int) -> SymlinkResolver {
        var config = SecurityLimitsConfig()
        config.maxSymlinkDepth = maxSymlinkDepth
        return SymlinkResolver(limits: config.toSecurityLimits())
    }
}
#endif
