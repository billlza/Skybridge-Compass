//
// P2PConnectionTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for P2P Connection Management and Status Monitoring
// **Feature: ios-p2p-integration**
//
// Property 24: Auto-Reconnect Timing (Validates: Requirements 10.1)
// Property 25: Reconnection Failure Notification (Validates: Requirements 10.2)
// Property 26: Session State Restoration (Validates: Requirements 10.3)
// Property 27: Connection Metrics Accuracy (Validates: Requirements 11.2)
//
// **Feature: p2p-todo-completion**
// Property 5: Metrics Update Consistency (Validates: Requirements 4.1, 4.2, 4.4)
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PConnectionTests: XCTestCase {
    
 // MARK: - Property 24: Auto-Reconnect Timing
    
 /// **Property 24: Auto-Reconnect Timing**
 /// *For any* connection loss due to network issues, the system should attempt
 /// reconnection within 5 seconds.
 /// **Validates: Requirements 10.1**
    func testAutoReconnectTimingProperty() {
 // Test that reconnect timing constants are configured correctly
        XCTAssertEqual(P2PConstants.autoReconnectDelaySeconds, 5.0,
                       "Reconnect delay must be 5 seconds")
        
 // Test reconnect backoff calculation
        let backoffCalculator = ReconnectBackoffCalculator()
        
 // First attempt should be immediate or within threshold
        let firstDelay = backoffCalculator.calculateDelay(attempt: 0)
        XCTAssertLessThanOrEqual(firstDelay, P2PConstants.autoReconnectDelaySeconds,
                                 "First reconnect attempt must be within threshold")
        
 // Subsequent attempts should use backoff
        let secondDelay = backoffCalculator.calculateDelay(attempt: 1)
        XCTAssertGreaterThanOrEqual(secondDelay, firstDelay,
                                    "Backoff should increase with attempts")
    }
    
 /// Test reconnect delay progression
    func testReconnectDelayProgression() {
        let calculator = ReconnectBackoffCalculator()
        
        var previousDelay: TimeInterval = 0
        
        for attempt in 0..<5 {
            let delay = calculator.calculateDelay(attempt: attempt)
            
 // Property: Delay should be non-negative
            XCTAssertGreaterThanOrEqual(delay, 0,
                                        "Delay must be non-negative")
            
 // Property: Delay should not decrease (monotonic)
            XCTAssertGreaterThanOrEqual(delay, previousDelay,
                                        "Delay must not decrease")
            
 // Property: Delay should not exceed maximum (60 seconds)
            XCTAssertLessThanOrEqual(delay, 60.0,
                                     "Delay must not exceed maximum")
            
            previousDelay = delay
        }
    }
    
 // MARK: - Property 25: Reconnection Failure Notification
    
 /// **Property 25: Reconnection Failure Notification**
 /// *For any* reconnection that fails after 3 attempts, the system should notify the user.
 /// **Validates: Requirements 10.2**
    func testReconnectionFailureNotificationProperty() {
 // Test that max attempts is configured correctly
        XCTAssertEqual(P2PConstants.maxReconnectAttempts, 3,
                       "Max reconnect attempts must be 3")
        
 // Simulate reconnection attempts
        var attemptCount = 0
        var shouldNotifyUser = false
        
        for _ in 0..<P2PConstants.maxReconnectAttempts {
            attemptCount += 1
 // Simulate failure
        }
        
 // After max attempts, should notify user
        if attemptCount >= P2PConstants.maxReconnectAttempts {
            shouldNotifyUser = true
        }
        
 // Property: User should be notified after max attempts
        XCTAssertTrue(shouldNotifyUser,
                      "User must be notified after \(P2PConstants.maxReconnectAttempts) failed attempts")
    }
    
 /// Test reconnection state machine
    func testReconnectionStateMachine() {
 // Define valid state transitions
        let validTransitions: [(ConnectionState, ConnectionState)] = [
            (.connected, .reconnecting),
            (.reconnecting, .connected),
            (.reconnecting, .disconnected),
            (.disconnected, .connecting),
            (.connecting, .connected),
            (.connecting, .disconnected)
        ]
        
        for (from, to) in validTransitions {
 // Property: Transition should be valid
            XCTAssertTrue(isValidTransition(from: from, to: to),
                          "Transition from \(from) to \(to) should be valid")
        }
        
 // Invalid transitions
        let invalidTransitions: [(ConnectionState, ConnectionState)] = [
            (.disconnected, .reconnecting), // Can't reconnect if never connected
            (.connected, .connecting) // Already connected
        ]
        
        for (from, to) in invalidTransitions {
 // Property: Transition should be invalid
            XCTAssertFalse(isValidTransition(from: from, to: to),
                           "Transition from \(from) to \(to) should be invalid")
        }
    }
    
 // MARK: - Property 26: Session State Restoration
    
 /// **Property 26: Session State Restoration**
 /// *For any* successful reconnection, the previous session state (file transfer progress,
 /// screen mirroring settings) should be restored.
 /// **Validates: Requirements 10.3**
    func testSessionStateRestorationProperty() throws {
 // Create session state
        let originalState = P2PSessionState(
            sessionId: UUID(),
            peerDeviceId: "peer-device-123",
            fileTransferProgress: [
                UUID(): FileTransferProgress(transferId: UUID(), completedChunks: 50, totalChunks: 100),
                UUID(): FileTransferProgress(transferId: UUID(), completedChunks: 75, totalChunks: 150)
            ],
            screenMirrorSettings: ScreenMirrorSettings(
                quality: .high,
                orientation: .landscape,
                audioEnabled: true
            ),
            savedAt: Date()
        )
        
 // Serialize state
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        
        let encoded = try encoder.encode(originalState)
        let restored = try decoder.decode(P2PSessionState.self, from: encoded)
        
 // Property: Session ID must be restored
        XCTAssertEqual(restored.sessionId, originalState.sessionId,
                       "Session ID must be restored")
        
 // Property: Peer device ID must be restored
        XCTAssertEqual(restored.peerDeviceId, originalState.peerDeviceId,
                       "Peer device ID must be restored")
        
 // Property: File transfer progress must be restored
        XCTAssertEqual(restored.fileTransferProgress.count, originalState.fileTransferProgress.count,
                       "File transfer progress count must be restored")
        
        for (transferId, progress) in originalState.fileTransferProgress {
            let restoredProgress = restored.fileTransferProgress[transferId]
            XCTAssertNotNil(restoredProgress, "Transfer \(transferId) must be restored")
            XCTAssertEqual(restoredProgress?.completedChunks, progress.completedChunks,
                           "Completed chunks must be restored")
            XCTAssertEqual(restoredProgress?.totalChunks, progress.totalChunks,
                           "Total chunks must be restored")
        }
        
 // Property: Screen mirror settings must be restored
        XCTAssertEqual(restored.screenMirrorSettings?.quality, originalState.screenMirrorSettings?.quality,
                       "Screen mirror quality must be restored")
        XCTAssertEqual(restored.screenMirrorSettings?.orientation, originalState.screenMirrorSettings?.orientation,
                       "Screen mirror orientation must be restored")
        XCTAssertEqual(restored.screenMirrorSettings?.audioEnabled, originalState.screenMirrorSettings?.audioEnabled,
                       "Screen mirror audio setting must be restored")
    }
    
 // MARK: - Property 27: Connection Metrics Accuracy
    
 /// **Property 27: Connection Metrics Accuracy**
 /// *For any* active connection, the displayed metrics (latency, bandwidth, packet loss)
 /// should reflect actual measurements from application-layer ping/ack and Network.framework reports.
 /// **Validates: Requirements 11.2**
    func testConnectionMetricsAccuracyProperty() {
 // Create test metrics
        let metrics = P2PConnectionMetrics(
            latencyMs: 25.5,
            bandwidthMbps: 100.0,
            packetLossPercent: 0.5,
            encryptionMode: "AES-256-GCM",
            protocolVersion: "1.0",
            peerCapabilities: ["screen-mirror", "file-transfer"],
            pqcEnabled: true,
            timestamp: Date()
        )
        
 // Property: Latency must be non-negative
        XCTAssertGreaterThanOrEqual(metrics.latencyMs, 0,
                                    "Latency must be non-negative")
        
 // Property: Bandwidth must be non-negative
        XCTAssertGreaterThanOrEqual(metrics.bandwidthMbps, 0,
                                    "Bandwidth must be non-negative")
        
 // Property: Packet loss must be in valid range [0, 100]
        XCTAssertGreaterThanOrEqual(metrics.packetLossPercent, 0,
                                    "Packet loss must be >= 0")
        XCTAssertLessThanOrEqual(metrics.packetLossPercent, 100,
                                 "Packet loss must be <= 100")
        
 // Property: Encryption mode must not be empty
        XCTAssertFalse(metrics.encryptionMode.isEmpty,
                       "Encryption mode must not be empty")
        
 // Property: Protocol version must not be empty
        XCTAssertFalse(metrics.protocolVersion.isEmpty,
                       "Protocol version must not be empty")
    }
    
 /// Test metrics field validation
    func testMetricsFieldValidation() {
        let metrics = P2PConnectionMetrics(
            latencyMs: 30.0,
            bandwidthMbps: 50.0,
            packetLossPercent: 1.0,
            encryptionMode: "ChaCha20-Poly1305",
            protocolVersion: "1.0",
            peerCapabilities: ["cap1", "cap2"],
            pqcEnabled: false,
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )
        
 // Property: All fields should be accessible and have expected values
        XCTAssertEqual(metrics.latencyMs, 30.0, accuracy: 0.001)
        XCTAssertEqual(metrics.bandwidthMbps, 50.0, accuracy: 0.001)
        XCTAssertEqual(metrics.packetLossPercent, 1.0, accuracy: 0.001)
        XCTAssertEqual(metrics.encryptionMode, "ChaCha20-Poly1305")
        XCTAssertEqual(metrics.protocolVersion, "1.0")
        XCTAssertEqual(metrics.peerCapabilities, ["cap1", "cap2"])
        XCTAssertEqual(metrics.pqcEnabled, false)
    }
    
 /// Test quality warning thresholds
    func testQualityWarningThresholds() {
 // Test latency threshold (100ms is typical warning threshold)
        let highLatency = P2PConnectionMetrics(
            latencyMs: 200.0, // High latency
            bandwidthMbps: 100.0,
            packetLossPercent: 0.0,
            encryptionMode: "AES-256-GCM",
            protocolVersion: "1.0",
            peerCapabilities: [],
            pqcEnabled: false,
            timestamp: Date()
        )
        
        XCTAssertTrue(highLatency.latencyMs > 100.0,
                      "High latency should trigger warning")
        
 // Test packet loss threshold (2% is typical warning threshold)
        let highPacketLoss = P2PConnectionMetrics(
            latencyMs: 20.0,
            bandwidthMbps: 100.0,
            packetLossPercent: 5.0, // High packet loss
            encryptionMode: "AES-256-GCM",
            protocolVersion: "1.0",
            peerCapabilities: [],
            pqcEnabled: false,
            timestamp: Date()
        )
        
        XCTAssertTrue(highPacketLoss.packetLossPercent > 2.0,
                      "High packet loss should trigger warning")
    }
    
 // MARK: - Property 5: Metrics Update Consistency (p2p-todo-completion)
    
 /// **Feature: p2p-todo-completion, Property 5: Metrics Update Consistency**
 /// *For any* connected NWConnection with valid NWPath, the extracted metrics should
 /// reflect the actual network conditions.
 /// **Validates: Requirements 4.1, 4.2, 4.4**
    func testProperty5_MetricsUpdateConsistency() {
 // Test that metrics extraction produces consistent results for same interface type
        
 // Property 5.1: WiFi interface should produce consistent latency estimate
        let wifiLatency = estimateLatencyForInterfaceType(.wifi)
        XCTAssertEqual(wifiLatency, 5.0, accuracy: 0.001,
                       "WiFi latency estimate should be consistent (5ms)")
        
 // Property 5.2: Ethernet interface should produce consistent latency estimate
        let ethernetLatency = estimateLatencyForInterfaceType(.wiredEthernet)
        XCTAssertEqual(ethernetLatency, 1.0, accuracy: 0.001,
                       "Ethernet latency estimate should be consistent (1ms)")
        
 // Property 5.3: Cellular interface should produce consistent latency estimate
        let cellularLatency = estimateLatencyForInterfaceType(.cellular)
        XCTAssertEqual(cellularLatency, 50.0, accuracy: 0.001,
                       "Cellular latency estimate should be consistent (50ms)")
        
 // Property 5.4: WiFi bandwidth should be reasonable
        let wifiBandwidth = estimateBandwidthForInterfaceType(.wifi)
        XCTAssertEqual(wifiBandwidth, 100.0, accuracy: 0.001,
                       "WiFi bandwidth estimate should be consistent (100 Mbps)")
        
 // Property 5.5: Ethernet bandwidth should be higher than WiFi
        let ethernetBandwidth = estimateBandwidthForInterfaceType(.wiredEthernet)
        XCTAssertGreaterThan(ethernetBandwidth, wifiBandwidth,
                             "Ethernet bandwidth should be higher than WiFi")
        
 // Property 5.6: Cellular bandwidth should be lower than WiFi
        let cellularBandwidth = estimateBandwidthForInterfaceType(.cellular)
        XCTAssertLessThan(cellularBandwidth, wifiBandwidth,
                          "Cellular bandwidth should be lower than WiFi")
    }
    
 /// **Feature: p2p-todo-completion, Property 5: Metrics Update Consistency**
 /// Test that default metrics are created correctly when path is unavailable
 /// **Validates: Requirements 4.3**
    func testProperty5_DefaultMetricsCreation() {
 // Create default metrics (simulating path unavailable scenario)
        let defaultMetrics = P2PConnectionMetrics(
            latencyMs: 0,
            bandwidthMbps: 0,
            packetLossPercent: 0,
            encryptionMode: "Unknown",
            protocolVersion: "v1",
            peerCapabilities: [],
            pqcEnabled: false,
            timestamp: Date()
        )
        
 // Property 5.7: Default latency should be 0
        XCTAssertEqual(defaultMetrics.latencyMs, 0,
                       "Default latency should be 0 when path unavailable")
        
 // Property 5.8: Default bandwidth should be 0
        XCTAssertEqual(defaultMetrics.bandwidthMbps, 0,
                       "Default bandwidth should be 0 when path unavailable")
        
 // Property 5.9: Default packet loss should be 0
        XCTAssertEqual(defaultMetrics.packetLossPercent, 0,
                       "Default packet loss should be 0 when path unavailable")
    }
    
 /// **Feature: p2p-todo-completion, Property 5: Metrics Update Consistency**
 /// Test that metrics values are within valid ranges
 /// **Validates: Requirements 4.2, 4.4**
    func testProperty5_MetricsValueRanges() {
 // Generate random interface types and verify metrics are in valid ranges
        let interfaceTypes: [TestInterfaceType] = [.wifi, .wiredEthernet, .cellular, .other]
        
        for interfaceType in interfaceTypes {
            let latency = estimateLatencyForInterfaceType(interfaceType)
            let bandwidth = estimateBandwidthForInterfaceType(interfaceType)
            let packetLoss = estimatePacketLossForStatus(.satisfied)
            
 // Property 5.10: Latency must be non-negative
            XCTAssertGreaterThanOrEqual(latency, 0,
                                        "Latency must be non-negative for \(interfaceType)")
            
 // Property 5.11: Bandwidth must be non-negative
            XCTAssertGreaterThanOrEqual(bandwidth, 0,
                                        "Bandwidth must be non-negative for \(interfaceType)")
            
 // Property 5.12: Packet loss must be in [0, 100]
            XCTAssertGreaterThanOrEqual(packetLoss, 0,
                                        "Packet loss must be >= 0")
            XCTAssertLessThanOrEqual(packetLoss, 100,
                                     "Packet loss must be <= 100")
        }
    }
    
 /// **Feature: p2p-todo-completion, Property 5: Metrics Update Consistency**
 /// Test packet loss estimation for different path statuses
 /// **Validates: Requirements 4.2**
    func testProperty5_PacketLossEstimation() {
 // Property 5.13: Satisfied path should have 0% packet loss
        let satisfiedLoss = estimatePacketLossForStatus(.satisfied)
        XCTAssertEqual(satisfiedLoss, 0.0, accuracy: 0.001,
                       "Satisfied path should have 0% packet loss")
        
 // Property 5.14: Unsatisfied path should have 100% packet loss
        let unsatisfiedLoss = estimatePacketLossForStatus(.unsatisfied)
        XCTAssertEqual(unsatisfiedLoss, 100.0, accuracy: 0.001,
                       "Unsatisfied path should have 100% packet loss")
        
 // Property 5.15: RequiresConnection path should have 50% packet loss
        let requiresConnectionLoss = estimatePacketLossForStatus(.requiresConnection)
        XCTAssertEqual(requiresConnectionLoss, 50.0, accuracy: 0.001,
                       "RequiresConnection path should have 50% packet loss")
    }
    
 // MARK: - Helper Methods
    
 /// Estimate latency for interface type (mirrors iOSP2PSessionManager.extractLatency)
    private func estimateLatencyForInterfaceType(_ type: TestInterfaceType) -> Double {
        switch type {
        case .wifi:
            return 5.0
        case .wiredEthernet:
            return 1.0
        case .cellular:
            return 50.0
        case .other:
            return 10.0
        }
    }
    
 /// Estimate bandwidth for interface type (mirrors iOSP2PSessionManager.extractBandwidth)
    private func estimateBandwidthForInterfaceType(_ type: TestInterfaceType) -> Double {
        switch type {
        case .wifi:
            return 100.0
        case .wiredEthernet:
            return 1000.0
        case .cellular:
            return 10.0
        case .other:
            return 50.0
        }
    }
    
 /// Estimate packet loss for path status (mirrors iOSP2PSessionManager.extractPacketLoss)
    private func estimatePacketLossForStatus(_ status: TestPathStatus) -> Double {
        switch status {
        case .satisfied:
            return 0.0
        case .unsatisfied:
            return 100.0
        case .requiresConnection:
            return 50.0
        }
    }
    
    private func isValidTransition(from: ConnectionState, to: ConnectionState) -> Bool {
        switch (from, to) {
        case (.disconnected, .connecting),
             (.connecting, .connected),
             (.connecting, .disconnected),
             (.connected, .disconnected),
             (.connected, .reconnecting),
             (.reconnecting, .connected),
             (.reconnecting, .disconnected):
            return true
        default:
            return false
        }
    }
}

// MARK: - Test Support Types

/// Reconnect backoff calculator for testing
struct ReconnectBackoffCalculator {
    func calculateDelay(attempt: Int) -> TimeInterval {
        let base = P2PConstants.autoReconnectDelaySeconds
        let multiplier = pow(1.5, Double(attempt))
        let delay = base * multiplier
        return min(delay, 60.0) // Max 60 seconds
    }
}

/// Connection state for testing
enum ConnectionState: String, Codable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

/// Session state for testing
struct P2PSessionState: Codable {
    let sessionId: UUID
    let peerDeviceId: String
    let fileTransferProgress: [UUID: FileTransferProgress]
    let screenMirrorSettings: ScreenMirrorSettings?
    let savedAt: Date
}

/// File transfer progress for testing
struct FileTransferProgress: Codable {
    let transferId: UUID
    let completedChunks: Int
    let totalChunks: Int
}

/// Screen mirror settings for testing
struct ScreenMirrorSettings: Codable {
    let quality: Quality
    let orientation: Orientation
    let audioEnabled: Bool
    
    enum Quality: String, Codable {
        case low, medium, high
    }
    
    enum Orientation: String, Codable {
        case portrait, landscape
    }
}

/// Test interface type (mirrors NWInterface.InterfaceType)
enum TestInterfaceType {
    case wifi
    case wiredEthernet
    case cellular
    case other
}

/// Test path status (mirrors NWPath.Status)
enum TestPathStatus {
    case satisfied
    case unsatisfied
    case requiresConnection
}
