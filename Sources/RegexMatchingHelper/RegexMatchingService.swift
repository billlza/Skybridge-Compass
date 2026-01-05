// MARK: - RegexMatchingService.swift
// SkyBridge Compass - Security Hardening
// XPC Service implementation for isolated regex matching
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// Thread-safe state container for regex matching operation.
private final class MatchingState: @unchecked Sendable {
    private let lock = NSLock()
    private var _didTimeout = false
    private var _didComplete = false
    private var _currentTask: DispatchWorkItem?
    
    var didTimeout: Bool {
        get { lock.withLock { _didTimeout } }
        set { lock.withLock { _didTimeout = newValue } }
    }
    
    var didComplete: Bool {
        get { lock.withLock { _didComplete } }
        set { lock.withLock { _didComplete = newValue } }
    }
    
    var currentTask: DispatchWorkItem? {
        get { lock.withLock { _currentTask } }
        set { lock.withLock { _currentTask = newValue } }
    }
    
 /// Atomically check and set timeout state.
 /// Returns true if we successfully set timeout (was not already complete).
    func trySetTimeout() -> Bool {
        lock.withLock {
            if _didComplete { return false }
            _didTimeout = true
            _currentTask?.cancel()
            _currentTask = nil
            return true
        }
    }
    
 /// Atomically check and set complete state.
 /// Returns true if we successfully set complete (was not already timed out).
    func trySetComplete() -> Bool {
        lock.withLock {
            if _didTimeout { return false }
            _didComplete = true
            return true
        }
    }
}

/// XPC Service implementation for regex matching.
///
/// **Security Properties**:
/// - Stateless: No persistent state between calls
/// - Isolated: Runs in separate process with minimal privileges
/// - Timeout-enforced: Hard wall-clock timeout terminates matching
///
/// This service is designed to be terminated by the parent process
/// if regex matching takes too long (ReDoS protection).
@objc public final class RegexMatchingService: NSObject, RegexMatchingProtocol, @unchecked Sendable {
    
 /// Maximum input size (1MB default, can be overridden)
    private let maxInputSize: Int
    
    public override init() {
        self.maxInputSize = 1024 * 1024 // 1MB default
        super.init()
    }
    
    public init(maxInputSize: Int) {
        self.maxInputSize = maxInputSize
        super.init()
    }
    
 // MARK: - RegexMatchingProtocol
    
    public func matchPattern(
        _ pattern: String,
        in inputData: Data,
        timeoutMs: Int,
        reply: @escaping @Sendable ([RegexMatchResult]?, RegexMatchError?) -> Void
    ) {
 // Check input size limit
        guard inputData.count <= maxInputSize else {
            reply(nil, .inputTooLarge(actual: inputData.count, max: maxInputSize))
            return
        }
        
 // Convert input data to string
        guard let inputString = String(data: inputData, encoding: .utf8) else {
            reply(nil, .internalError("Failed to decode input as UTF-8"))
            return
        }
        
 // Create regex
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            reply(nil, .invalidPattern(error.localizedDescription))
            return
        }
        
 // Create thread-safe state container
        let state = MatchingState()
        let timeoutSeconds = Double(timeoutMs) / 1000.0
        
 // Create work item for matching
        let workItem = DispatchWorkItem {
 // Perform matching
            let range = NSRange(inputString.startIndex..., in: inputString)
            let matches = regex.matches(in: inputString, options: [], range: range)
            
 // Check if we timed out while matching
            guard state.trySetComplete() else {
                return // Timeout handler already replied
            }
            
 // Convert matches to results
            let results = matches.map { match -> RegexMatchResult in
                var capturedGroups: [String] = []
                for i in 0..<match.numberOfRanges {
                    let groupRange = match.range(at: i)
                    if groupRange.location != NSNotFound,
                       let swiftRange = Range(groupRange, in: inputString) {
                        capturedGroups.append(String(inputString[swiftRange]))
                    } else {
                        capturedGroups.append("")
                    }
                }
                return RegexMatchResult(
                    location: match.range.location,
                    length: match.range.length,
                    capturedGroups: capturedGroups
                )
            }
            
            reply(results, nil)
        }
        
 // Store work item for potential cancellation
        state.currentTask = workItem
        
 // Schedule timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            guard state.trySetTimeout() else {
                return // Already completed
            }
            reply(nil, .timeout())
        }
        
 // Execute matching on background queue
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
    
    public func ping(reply: @escaping @Sendable (Bool) -> Void) {
        reply(true)
    }
}

// MARK: - XPC Service Delegate

/// XPC Service delegate for connection handling.
@objc public class RegexMatchingServiceDelegate: NSObject, NSXPCListenerDelegate {
    
    private let maxInputSize: Int
    
    public init(maxInputSize: Int = 1024 * 1024) {
        self.maxInputSize = maxInputSize
        super.init()
    }
    
    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
 // Configure the connection
        newConnection.exportedInterface = NSXPCInterface(with: RegexMatchingProtocol.self)
        
 // Register allowed classes for secure coding
        let interface = newConnection.exportedInterface!
        let resultClasses = NSSet(array: [
            NSArray.self,
            RegexMatchResult.self,
            RegexMatchError.self,
            NSString.self
        ])
        guard let classSet = resultClasses as? Set<AnyHashable> else {
            return false
        }
        interface.setClasses(
            classSet,
            for: #selector(RegexMatchingProtocol.matchPattern(_:in:timeoutMs:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        
 // Create and export the service object
        let service = RegexMatchingService(maxInputSize: maxInputSize)
        newConnection.exportedObject = service
        
 // Resume the connection
        newConnection.resume()
        
        return true
    }
}
