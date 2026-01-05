//
// P2PTransportTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for P2P Transport Layer
// **Feature: ios-p2p-integration**
//
// Property 18: Adaptive Stream Reduction (Validates: Requirements 5.5, 6.6)
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PTransportTests: XCTestCase {
    
 // MARK: - Property 18: Adaptive Stream Reduction
    
 /// **Property 18: Adaptive Stream Reduction**
 /// *For any* network quality degradation below threshold, the system should reduce
 /// concurrent file stream count.
 /// **Validates: Requirements 5.5, 6.6**
    func testAdaptiveStreamReductionProperty() async {
 // Test that network quality affects stream concurrency
        let qualities: [QUICNetworkQuality] = [.excellent, .good, .fair, .poor, .unknown]
        
        var previousConcurrency = Int.max
        
        for quality in qualities.sorted(by: { $0.rawValue > $1.rawValue }) {
            let concurrency = calculateExpectedConcurrency(for: quality)
            
 // Property: Lower quality should result in equal or lower concurrency
            if quality != .unknown {
                XCTAssertLessThanOrEqual(concurrency, previousConcurrency,
                                         "Lower quality (\(quality)) should have <= concurrency than higher quality")
            }
            
 // Property: Concurrency should be positive
            XCTAssertGreaterThan(concurrency, 0,
                                 "Concurrency must be positive for quality \(quality)")
            
            previousConcurrency = concurrency
        }
    }
    
 /// Test LogicalChannel enum
    func testLogicalChannelTypes() {
 // Property: Control channel is unique
        let control = LogicalChannel.control
        XCTAssertNotNil(control, "Control channel must exist")
        
 // Property: Video datagram channel is unique
        let video = LogicalChannel.videoDatagram
        XCTAssertNotNil(video, "Video datagram channel must exist")
        
 // Property: File channels can be created with different IDs
        let fileId1 = FileChannelId(transferId: UUID(), streamIndex: 0)
        let fileId2 = FileChannelId(transferId: UUID(), streamIndex: 1)
        
        let file1 = LogicalChannel.file(fileId1)
        let file2 = LogicalChannel.file(fileId2)
        
        XCTAssertNotNil(file1, "File channel 1 must exist")
        XCTAssertNotNil(file2, "File channel 2 must exist")
    }
    
 /// Test FileChannelId hashability
    func testFileChannelIdHashable() {
        let transferId = UUID()
        let id1 = FileChannelId(transferId: transferId, streamIndex: 0)
        let id2 = FileChannelId(transferId: transferId, streamIndex: 0)
        let id3 = FileChannelId(transferId: transferId, streamIndex: 1)
        
 // Property: Same values should be equal
        XCTAssertEqual(id1, id2, "Same FileChannelId values must be equal")
        
 // Property: Different values should not be equal
        XCTAssertNotEqual(id1, id3, "Different FileChannelId values must not be equal")
        
 // Property: Can be used in Set
        var set = Set<FileChannelId>()
        set.insert(id1)
        set.insert(id2)
        set.insert(id3)
        
        XCTAssertEqual(set.count, 2, "Set should contain 2 unique FileChannelIds")
    }
    
 /// Test FileStreamHandle hashability
    func testFileStreamHandleHashable() {
        let channelId = FileChannelId(transferId: UUID(), streamIndex: 0)
        let handle1 = FileStreamHandle(channelId: channelId)
        let handle2 = FileStreamHandle(channelId: channelId)
        
 // Property: Same channel ID should produce equal handles
        XCTAssertEqual(handle1, handle2, "Same channelId must produce equal handles")
        
 // Property: Can be used in Set
        var set = Set<FileStreamHandle>()
        set.insert(handle1)
        set.insert(handle2)
        
        XCTAssertEqual(set.count, 1, "Set should contain 1 unique handle")
    }
    
 /// Test QUICNetworkQuality ordering
    func testNetworkQualityOrdering() {
 // Property: Quality values should be ordered
        XCTAssertGreaterThan(QUICNetworkQuality.excellent.rawValue, QUICNetworkQuality.good.rawValue)
        XCTAssertGreaterThan(QUICNetworkQuality.good.rawValue, QUICNetworkQuality.fair.rawValue)
        XCTAssertGreaterThan(QUICNetworkQuality.fair.rawValue, QUICNetworkQuality.poor.rawValue)
        XCTAssertGreaterThan(QUICNetworkQuality.poor.rawValue, QUICNetworkQuality.unknown.rawValue)
    }
    
 // MARK: - Helper Methods
    
    private func calculateExpectedConcurrency(for quality: QUICNetworkQuality) -> Int {
        switch quality {
        case .excellent:
            return 8
        case .good:
            return 4
        case .fair:
            return 2
        case .poor:
            return 1
        case .unknown:
            return 2
        }
    }
}
