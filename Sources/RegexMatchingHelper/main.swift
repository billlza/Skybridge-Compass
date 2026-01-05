// MARK: - main.swift
// SkyBridge Compass - Security Hardening
// XPC Helper entry point for isolated regex matching
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// XPC Helper for regex matching with minimal privileges.
///
/// **Security Constraints (Critical)**:
/// - Stateless: No persistent state
/// - No file system access: Does not read/write files
/// - No network access: Does not connect to network
/// - Input limited: Only accepts pattern + input bytes
/// - Output limited: Only returns match results or errors
///
/// This helper is designed to be terminated by the parent process
/// if regex matching exceeds the timeout (ReDoS protection).

// Create the XPC listener with the service delegate
let delegate = RegexMatchingServiceDelegate(
    maxInputSize: 1024 * 1024 // 1MB - matches SecurityLimits.default.perPatternInputLimit
)

// Create anonymous listener for XPC service
let listener = NSXPCListener.anonymous()
listener.delegate = delegate

// Resume the listener
listener.resume()

// Run the run loop to keep the service alive
RunLoop.current.run()
