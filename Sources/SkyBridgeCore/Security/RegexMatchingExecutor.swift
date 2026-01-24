// MARK: - RegexMatchingExecutor.swift
// SkyBridge Compass - Security Hardening
// Isolated regex matching executor with XPC isolation and hard timeout
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

// MARK: - RegexMatchResult (Internal)

/// Result of a regex match operation.
/// Mirrors the XPC helper's RegexMatchResult for internal use.
public struct RegexMatchResultInternal: Sendable {
 /// Range location in the input
    public let location: Int

 /// Range length
    public let length: Int

 /// Captured groups (if any)
    public let capturedGroups: [String]

    public init(location: Int, length: Int, capturedGroups: [String] = []) {
        self.location = location
        self.length = length
        self.capturedGroups = capturedGroups
    }
}

// MARK: - RegexMatchingError

/// Errors from regex matching operations.
public enum RegexMatchingError: Error, Sendable {
 /// Matching timed out
    case timeout

 /// Invalid regex pattern
    case invalidPattern(String)

 /// Input data too large
    case inputTooLarge(actual: Int, max: Int)

 /// XPC connection failed
    case connectionFailed(String)

 /// Internal error
    case internalError(String)

 /// Matching was cancelled
    case cancelled
}

// MARK: - RegexMatchingExecutor

/// Regex matching executor with XPC isolation and hard timeout.
///
/// **Design Rationale**:
/// NSRegularExpression has no native timeout mechanism, and .cancel cannot
/// interrupt the underlying backtracking. Therefore, regex matching MUST run
/// in an isolated environment where timeout can be enforced by process termination.
///
/// **Implementation Strategy**:
/// - Regex matching runs in an isolated XPC helper process
/// - XPC helper has independent wall-clock timeout (perPatternTimeout)
/// - On timeout: terminate helper process, mark pattern as unsafe
/// - This is a native macOS capability, not a third-party dependency
///
/// **XPC Helper Minimum Privilege Constraints (Critical)**:
/// - Stateless: No persistent state
/// - No file system access entitlement: Does not read files
/// - No network entitlement: Does not connect to network
/// - Input only: pattern string + input bytes (limited to perPatternInputLimit)
/// - Output only: match results or timeout/error
///
/// **Fallback Strategy**:
/// If XPC is not available (e.g., in unit tests), falls back to in-process
/// matching with -based timeout. Note: cancellation is best-effort
/// and may not interrupt NSRegularExpression backtracking.
public actor RegexMatchingExecutor {

 // MARK: - Properties

 /// Security limits configuration
    private let limits: SecurityLimits

 /// Whether to use XPC isolation (can be disabled for testing)
    private let useXPCIsolation: Bool

 /// XPC connection to helper (lazy initialized)
    private var xpcConnection: NSXPCConnection?

 /// Whether XPC helper is available
    private var xpcAvailable: Bool?

    /// Backoff until next XPC retry (avoid log spam when helper is not present)
    private var nextXPCRetryAt: Date = .distantPast

 // MARK: - Initialization

 /// Initialize with security limits.
 ///
 /// - Parameters:
 /// - limits: Security limits configuration
 /// - useXPCIsolation: Whether to use XPC isolation (default: true)
    public init(limits: SecurityLimits = .default, useXPCIsolation: Bool = true) {
        self.limits = limits
        self.useXPCIsolation = useXPCIsolation
    }

 // MARK: - Public API

 /// Execute regex matching with timeout protection.
 ///
 /// - Parameters:
 /// - pattern: The compiled NSRegularExpression
 /// - text: The text to match against
 /// - Returns: Array of match results, or nil if timeout/error
 /// - Throws: RegexMatchingError on failure
    public func match(
        pattern: NSRegularExpression,
        in text: String
    ) async throws -> [RegexMatchResultInternal] {
 // Check input size limit
        let inputData = Data(text.utf8)
        guard inputData.count <= limits.perPatternInputLimit else {
            throw RegexMatchingError.inputTooLarge(
                actual: inputData.count,
                max: limits.perPatternInputLimit
            )
        }

 // Try XPC isolation first, fall back to in-process if unavailable
        if useXPCIsolation {
            // If we've already detected the helper is unavailable, skip XPC and fall back immediately.
            if xpcAvailable == false || Date() < nextXPCRetryAt {
                return try await matchInProcess(pattern: pattern, text: text)
            }
            do {
                return try await matchViaXPC(pattern: pattern.pattern, inputData: inputData)
            } catch RegexMatchingError.connectionFailed {
 // XPC not available, fall back to in-process
                return try await matchInProcess(pattern: pattern, text: text)
            }
        } else {
            return try await matchInProcess(pattern: pattern, text: text)
        }
    }

 /// Execute regex matching with a pattern string.
 ///
 /// - Parameters:
 /// - patternString: The regex pattern string
 /// - text: The text to match against
 /// - Returns: Array of match results
 /// - Throws: RegexMatchingError on failure
    public func match(
        patternString: String,
        in text: String
    ) async throws -> [RegexMatchResultInternal] {
 // Create regex
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: patternString, options: [])
        } catch {
            throw RegexMatchingError.invalidPattern(error.localizedDescription)
        }

        return try await match(pattern: regex, in: text)
    }

 /// Terminate the XPC helper process.
 /// Call this when the executor is no longer needed.
    public func terminate() {
        xpcConnection?.invalidate()
        xpcConnection = nil
    }

 // MARK: - XPC Matching

 /// Match via XPC helper process.
    private func matchViaXPC(
        pattern: String,
        inputData: Data
    ) async throws -> [RegexMatchResultInternal] {
 // Get or create XPC connection
        let connection = try getOrCreateXPCConnection()

        // Get remote proxy (with error handler so we can disable XPC on failure)
        let proxyAny = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { [weak self] in
                await self?.markXPCUnavailableAndBackoff()
            }
        }
        guard let proxy = proxyAny as? RegexMatchingProtocolProxy else {
            markXPCUnavailableAndBackoff()
            throw RegexMatchingError.connectionFailed("Failed to get XPC proxy")
        }

 // Calculate timeout in milliseconds
        let timeoutMs = Int(limits.perPatternTimeout * 1000)

 // Perform matching via XPC
        return try await withCheckedThrowingContinuation { continuation in
            proxy.matchPattern(pattern, in: inputData, timeoutMs: timeoutMs) { results, error in
                if let error = error {
                    // Helper responded but indicates failure; if it looks like an XPC-layer issue, back off.
                    if error.code == 4 {
                        Task { [weak self] in
                            await self?.markXPCUnavailableAndBackoff()
                        }
                    }
                    switch error.code {
                    case 1: // timeout
                        continuation.resume(throwing: RegexMatchingError.timeout)
                    case 2: // invalid pattern
                        continuation.resume(throwing: RegexMatchingError.invalidPattern(error.message))
                    case 3: // input too large
                        continuation.resume(throwing: RegexMatchingError.inputTooLarge(actual: 0, max: 0))
                    case 5: // cancelled
                        continuation.resume(throwing: RegexMatchingError.cancelled)
                    default:
                        continuation.resume(throwing: RegexMatchingError.internalError(error.message))
                    }
                } else if let results = results {
                    let internalResults = results.map { result in
                        RegexMatchResultInternal(
                            location: result.location,
                            length: result.length,
                            capturedGroups: result.capturedGroups
                        )
                    }
                    Task { [weak self] in
                        // Mark helper as available after a successful round-trip.
                        await self?.markXPCAvailable()
                    }
                    continuation.resume(returning: internalResults)
                } else {
                    Task { [weak self] in
                        await self?.markXPCAvailable()
                    }
                    continuation.resume(returning: [])
                }
            }
        }
    }

 /// Get or create XPC connection to helper.
    private func getOrCreateXPCConnection() throws -> NSXPCConnection {
        if xpcAvailable == false || Date() < nextXPCRetryAt {
            throw RegexMatchingError.connectionFailed("XPC helper unavailable")
        }
        if let connection = xpcConnection {
            return connection
        }

 // Create new connection to XPC service
 // Note: In production, this would connect to a bundled XPC service
 // For now, we use a Mach service name
        let connection = NSXPCConnection(
            serviceName: "com.skybridge.RegexMatchingHelper"
        )

 // Configure interface
        connection.remoteObjectInterface = NSXPCInterface(
            with: RegexMatchingProtocolProxy.self
        )

 // Set up error handler
        connection.invalidationHandler = { [weak self] in
            Task { [weak self] in
                await self?.handleConnectionInvalidation()
            }
        }

        connection.interruptionHandler = { [weak self] in
            Task { [weak self] in
                await self?.handleConnectionInterruption()
            }
        }

 // Resume connection
        connection.resume()

 // Store connection
        xpcConnection = connection
        // Optimistically mark as available; will be flipped to unavailable on invalidation/error.
        xpcAvailable = true

        return connection
    }

 /// Handle XPC connection invalidation.
    private func handleConnectionInvalidation() {
        xpcConnection = nil
        xpcAvailable = false
        // Back off to avoid repeated connect spam/logs when helper isn't present.
        nextXPCRetryAt = Date().addingTimeInterval(60)
    }

 /// Handle XPC connection interruption.
    private func handleConnectionInterruption() {
 // Connection interrupted, will be re-established on next use
        xpcConnection?.invalidate()
        xpcConnection = nil
        xpcAvailable = false
        nextXPCRetryAt = Date().addingTimeInterval(60)
    }

    private func markXPCUnavailableAndBackoff() {
        xpcConnection?.invalidate()
        xpcConnection = nil
        xpcAvailable = false
        nextXPCRetryAt = Date().addingTimeInterval(60)
    }

    private func markXPCAvailable() {
        // Clear backoff on success
        xpcAvailable = true
        nextXPCRetryAt = .distantPast
    }

 // MARK: - In-Process Matching (Fallback)

 /// Match in-process with -based timeout.
 ///
 /// **Warning**: cancellation is best-effort and may not interrupt
 /// NSRegularExpression backtracking. This is a fallback for when XPC
 /// is not available (e.g., unit tests).
    private func matchInProcess(
        pattern: NSRegularExpression,
        text: String
    ) async throws -> [RegexMatchResultInternal] {
 // Create timeout
        let timeoutNanoseconds = UInt64(limits.perPatternTimeout * 1_000_000_000)

        return try await withThrowingTaskGroup(of: [RegexMatchResultInternal].self) { group in
 // Add matching
            group.addTask {
                let range = NSRange(text.startIndex..., in: text)
                let matches = pattern.matches(in: text, options: [], range: range)

 // Check for cancellation
                try Task.checkCancellation()

                return matches.map { match in
                    var capturedGroups: [String] = []
                    for i in 0..<match.numberOfRanges {
                        let groupRange = match.range(at: i)
                        if groupRange.location != NSNotFound,
                           let swiftRange = Range(groupRange, in: text) {
                            capturedGroups.append(String(text[swiftRange]))
                        } else {
                            capturedGroups.append("")
                        }
                    }
                    return RegexMatchResultInternal(
                        location: match.range.location,
                        length: match.range.length,
                        capturedGroups: capturedGroups
                    )
                }
            }

 // Add timeout
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw RegexMatchingError.timeout
            }

 // Wait for first result
            guard let result = try await group.next() else {
                throw RegexMatchingError.internalError("No result from task group")
            }

 // Cancel remaining tasks
            group.cancelAll()

            return result
        }
    }
}

// MARK: - XPC Protocol Proxy

/// Protocol proxy for XPC communication.
/// This mirrors the RegexMatchingProtocol from the helper target.
@objc protocol RegexMatchingProtocolProxy {
    func matchPattern(
        _ pattern: String,
        in inputData: Data,
        timeoutMs: Int,
        reply: @escaping @Sendable ([RegexMatchResultProxy]?, RegexMatchErrorProxy?) -> Void
    )

    func ping(reply: @escaping @Sendable (Bool) -> Void)
}

/// Proxy class for regex match results.
@objc class RegexMatchResultProxy: NSObject, NSSecureCoding {
    @objc let location: Int
    @objc let length: Int
    @objc let capturedGroups: [String]

    init(location: Int, length: Int, capturedGroups: [String]) {
        self.location = location
        self.length = length
        self.capturedGroups = capturedGroups
        super.init()
    }

    static var supportsSecureCoding: Bool { true }

    func encode(with coder: NSCoder) {
        coder.encode(location, forKey: "location")
        coder.encode(length, forKey: "length")
        coder.encode(capturedGroups, forKey: "capturedGroups")
    }

    required init?(coder: NSCoder) {
        self.location = coder.decodeInteger(forKey: "location")
        self.length = coder.decodeInteger(forKey: "length")
        self.capturedGroups = coder.decodeObject(
            of: [NSArray.self, NSString.self],
            forKey: "capturedGroups"
        ) as? [String] ?? []
        super.init()
    }
}

/// Proxy class for regex match errors.
@objc class RegexMatchErrorProxy: NSObject, NSSecureCoding {
    @objc let code: Int
    @objc let message: String

    init(code: Int, message: String) {
        self.code = code
        self.message = message
        super.init()
    }

    static var supportsSecureCoding: Bool { true }

    func encode(with coder: NSCoder) {
        coder.encode(code, forKey: "code")
        coder.encode(message, forKey: "message")
    }

    required init?(coder: NSCoder) {
        self.code = coder.decodeInteger(forKey: "code")
        self.message = coder.decodeObject(of: NSString.self, forKey: "message") as? String ?? ""
        super.init()
    }
}

// MARK: - Testing Support

#if DEBUG
extension RegexMatchingExecutor {
 /// Create an executor for testing without XPC isolation.
    public static func createForTesting(limits: SecurityLimits = .default) -> RegexMatchingExecutor {
        RegexMatchingExecutor(limits: limits, useXPCIsolation: false)
    }
}
#endif
