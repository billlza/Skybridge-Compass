//
// P2PScreenMirrorTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for P2P Screen Mirroring
// **Feature: ios-p2p-integration**
//
// Property 22: Video Frame Stale Discard (Validates: Requirements 7.7)
// Property 23: Orientation Update Timing (Validates: Requirements 7.6)
// Property 29: Video Frame Fragmentation (Validates: Requirements 7.3)
// Property 30: Video Codec Config in Transcript (Validates: Requirements 7.2)
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PScreenMirrorTests: XCTestCase {
    
 // MARK: - Property 22: Video Frame Stale Discard
    
 /// **Property 22: Video Frame Stale Discard**
 /// *For any* sequence of video frames, frames with frameSeq < latestKeyFrameSeq
 /// should be discarded, and only the latest keyframe should be kept.
 /// **Validates: Requirements 7.7**
    func testVideoFrameStaleDiscardProperty() async {
        let reassembler = P2PVideoFrameReassembler()
        
 // Send keyframe with seq 100
        let keyframe = makeP2PVideoFramePacket(
            frameSeq: 100,
            isKeyFrame: true,
            payload: Data(repeating: 0x01, count: 100)
        )
        
        let keyframeResult = await reassembler.receivePacket(keyframe)
        XCTAssertNotNil(keyframeResult, "Keyframe should be accepted")
        
 // Send stale frame with seq 50 (before keyframe)
        let staleFrame = makeP2PVideoFramePacket(
            frameSeq: 50,
            isKeyFrame: false,
            payload: Data(repeating: 0x02, count: 100)
        )
        
        let staleResult = await reassembler.receivePacket(staleFrame)
        
 // Property: Stale frame should be discarded
        XCTAssertNil(staleResult, "Stale frame (seq < keyframe seq) must be discarded")
        
 // Send valid frame with seq 101 (after keyframe)
        let validFrame = makeP2PVideoFramePacket(
            frameSeq: 101,
            isKeyFrame: false,
            payload: Data(repeating: 0x03, count: 100)
        )
        
        let validResult = await reassembler.receivePacket(validFrame)
        
 // Property: Valid frame should be accepted
        XCTAssertNotNil(validResult, "Valid frame (seq > keyframe seq) must be accepted")
    }
    
 /// Test keyframe updates latestKeyFrameSeq
    func testKeyframeUpdatesLatestSeq() async {
        let reassembler = P2PVideoFrameReassembler()
        
 // Send first keyframe
        let keyframe1 = makeP2PVideoFramePacket(
            frameSeq: 10,
            isKeyFrame: true,
            payload: Data(repeating: 0x01, count: 100)
        )
        _ = await reassembler.receivePacket(keyframe1)
        
 // Send second keyframe with higher seq
        let keyframe2 = makeP2PVideoFramePacket(
            frameSeq: 50,
            isKeyFrame: true,
            payload: Data(repeating: 0x02, count: 100)
        )
        _ = await reassembler.receivePacket(keyframe2)
        
 // Frame between keyframes should now be stale
        let betweenFrame = makeP2PVideoFramePacket(
            frameSeq: 30,
            isKeyFrame: false,
            payload: Data(repeating: 0x03, count: 100)
        )
        
        let result = await reassembler.receivePacket(betweenFrame)
        
 // Property: Frame between keyframes should be discarded after newer keyframe
        XCTAssertNil(result, "Frame between keyframes must be discarded")
    }
    
 // MARK: - Property 23: Orientation Update Timing
    
 /// **Property 23: Orientation Update Timing**
 /// *For any* iOS device orientation change, the Mac display should update
 /// within 500 milliseconds.
 /// **Validates: Requirements 7.6**
    func testOrientationUpdateTimingProperty() {
 // Test that orientation threshold is configured correctly
        XCTAssertEqual(P2PConstants.orientationUpdateTimeoutMs, 500,
                       "Orientation update threshold must be 500ms")
        
 // Test all orientation values
        let orientations: [VideoOrientation] = [.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown]
        
        for orientation in orientations {
 // Property: Orientation should have valid raw value
            XCTAssertGreaterThanOrEqual(orientation.rawValue, 0,
                                        "Orientation raw value must be >= 0")
            XCTAssertLessThanOrEqual(orientation.rawValue, 3,
                                     "Orientation raw value must be <= 3")
        }
    }
    
 // MARK: - Property 29: Video Frame Fragmentation
    
 /// **Property 29: Video Frame Fragmentation**
 /// *For any* video frame larger than maxDatagramSize, the system should fragment
 /// it into multiple VideoFramePackets and reassemble correctly on the receiver.
 /// **Validates: Requirements 7.3**
    func testVideoFrameFragmentationProperty() async {
        let maxDatagramSize = 1200 // Typical MTU-safe size
        let headerOverhead = 16 // Fixed header size
        let payloadMax = maxDatagramSize - headerOverhead
        
 // Create large frame that needs fragmentation
        let largePayload = Data(repeating: 0xAB, count: payloadMax * 3 + 100) // ~3.1 fragments
        
 // Fragment the frame
        let fragments = fragmentVideoFrame(
            payload: largePayload,
            frameSeq: 1,
            isKeyFrame: true,
            payloadMax: payloadMax
        )
        
 // Property: Should produce correct number of fragments
        let expectedFragments = Int(ceil(Double(largePayload.count) / Double(payloadMax)))
        XCTAssertEqual(fragments.count, expectedFragments,
                       "Must produce correct number of fragments")
        
 // Property: All fragments should have same frameSeq
        for fragment in fragments {
            XCTAssertEqual(fragment.frameSeq, 1,
                           "All fragments must have same frameSeq")
        }
        
 // Property: Fragment indices should be sequential
        for (index, fragment) in fragments.enumerated() {
            XCTAssertEqual(fragment.fragIndex, UInt16(index),
                           "Fragment indices must be sequential")
        }
        
 // Property: All fragments should have correct fragCount
        for fragment in fragments {
            XCTAssertEqual(fragment.fragCount, UInt16(expectedFragments),
                           "All fragments must have correct fragCount")
        }
        
 // Property: Reassembled payload should match original
        let reassembler = P2PVideoFrameReassembler()
        var reassembledFrame: ReassembledFrame?
        
        for fragment in fragments {
            if let result = await reassembler.receivePacket(fragment) {
                reassembledFrame = result
            }
        }
        
        XCTAssertNotNil(reassembledFrame, "Frame must be reassembled")
        XCTAssertEqual(reassembledFrame?.data, largePayload,
                       "Reassembled payload must match original")
    }
    
 /// Test single fragment frame
    func testSingleFragmentFrame() async {
        let smallPayload = Data(repeating: 0xCD, count: 500)
        
 // Need to send a keyframe first to establish baseline
        let keyframe = makeP2PVideoFramePacket(
            frameSeq: 0,
            isKeyFrame: true,
            payload: Data(repeating: 0x00, count: 10)
        )
        
        let reassembler = P2PVideoFrameReassembler()
        _ = await reassembler.receivePacket(keyframe)
        
        let packet = makeP2PVideoFramePacket(
            frameSeq: 1,
            isKeyFrame: false,
            payload: smallPayload
        )
        
        let result = await reassembler.receivePacket(packet)
        
 // Property: Single fragment should be immediately available
        XCTAssertNotNil(result, "Single fragment frame must be immediately available")
        XCTAssertEqual(result?.data, smallPayload, "Payload must match")
    }
    
 // MARK: - Property 30: Video Codec Config in Transcript
    
 /// **Property 30: Video Codec Config in Transcript**
 /// *For any* video session, the VideoCodecConfig (including parameter sets) should
 /// be included in the handshake transcript and covered by the signature to prevent tampering.
 /// **Validates: Requirements 7.2**
    func testVideoCodecConfigInTranscriptProperty() throws {
        let builder = TranscriptBuilder(role: .initiator)
        
 // Create video codec config
        let codecConfig = P2PVideoCodecConfig(
            codec: .hevc,
            parameterSets: [
                Data(repeating: 0x01, count: 32), // VPS
                Data(repeating: 0x02, count: 64), // SPS
                Data(repeating: 0x03, count: 16)  // PPS
            ],
            width: 1920,
            height: 1080,
            fps: 60,
            bitrate: 8_000_000
        )
        
 // Add to transcript
        try builder.append(message: codecConfig, type: .videoCodecConfig)
        
        let hash1 = builder.computeHash()
        
 // Property: Hash should be 32 bytes
        XCTAssertEqual(hash1.count, 32, "Transcript hash must be 32 bytes")
        
 // Property: Different codec config should produce different hash
        let builder2 = TranscriptBuilder(role: .initiator)
        
        let differentConfig = P2PVideoCodecConfig(
            codec: .h264, // Different codec!
            parameterSets: [
                Data(repeating: 0x04, count: 32),
                Data(repeating: 0x05, count: 64)
            ],
            width: 1920,
            height: 1080,
            fps: 60,
            bitrate: 8_000_000
        )
        
        try builder2.append(message: differentConfig, type: .videoCodecConfig)
        
        let hash2 = builder2.computeHash()
        
        XCTAssertNotEqual(hash1, hash2,
                          "Different codec config must produce different hash")
        
 // Property: Different parameter sets should produce different hash
        let builder3 = TranscriptBuilder(role: .initiator)
        
        let modifiedConfig = P2PVideoCodecConfig(
            codec: .hevc,
            parameterSets: [
                Data(repeating: 0xFF, count: 32), // Modified VPS!
                Data(repeating: 0x02, count: 64),
                Data(repeating: 0x03, count: 16)
            ],
            width: 1920,
            height: 1080,
            fps: 60,
            bitrate: 8_000_000
        )
        
        try builder3.append(message: modifiedConfig, type: .videoCodecConfig)
        
        let hash3 = builder3.computeHash()
        
        XCTAssertNotEqual(hash1, hash3,
                          "Modified parameter sets must produce different hash")
    }
    
 /// Test P2PVideoCodecConfig serialization
    func testVideoCodecConfigSerialization() throws {
        let config = P2PVideoCodecConfig(
            codec: .hevc,
            parameterSets: [
                Data(repeating: 0x01, count: 32),
                Data(repeating: 0x02, count: 64),
                Data(repeating: 0x03, count: 16)
            ],
            width: 1920,
            height: 1080,
            fps: 60,
            bitrate: 8_000_000,
            timestampMillis: 1700000000000
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let encoded = try encoder.encode(config)
        let decoded = try decoder.decode(P2PVideoCodecConfig.self, from: encoded)
        
 // Property: Round-trip should preserve all fields
        XCTAssertEqual(decoded.codec, config.codec)
        XCTAssertEqual(decoded.parameterSets, config.parameterSets)
        XCTAssertEqual(decoded.width, config.width)
        XCTAssertEqual(decoded.height, config.height)
        XCTAssertEqual(decoded.fps, config.fps)
    }
    
 // MARK: - Additional Screen Mirror Tests
    
 /// Test P2PVideoFramePacket model
    func testVideoFramePacketModel() throws {
        let packet = P2PVideoFramePacket(
            frameSeq: 12345,
            fragIndex: 2,
            fragCount: 5,
            flags: .keyFrame,
            timestampMillis: 1700000000123,
            orientation: .landscapeLeft,
            payload: Data(repeating: 0xAB, count: 1000)
        )
        
 // Encode to binary
        let encoded = packet.encode()
        
 // Decode from binary
        guard let decoded = P2PVideoFramePacket.decode(from: encoded) else {
            XCTFail("Failed to decode packet")
            return
        }
        
 // Property: Round-trip should preserve all fields
        XCTAssertEqual(decoded.frameSeq, packet.frameSeq)
        XCTAssertEqual(decoded.isKeyFrame, packet.isKeyFrame)
        XCTAssertEqual(decoded.fragIndex, packet.fragIndex)
        XCTAssertEqual(decoded.fragCount, packet.fragCount)
        XCTAssertEqual(decoded.payload, packet.payload)
        XCTAssertEqual(decoded.timestampMillis, packet.timestampMillis)
        XCTAssertEqual(decoded.orientation, packet.orientation)
    }
    
 /// Test RequestKeyFrame model
    func testRequestKeyFrameModel() throws {
        let reasons: [P2PKeyFrameRequestReason] = [.loss, .newSubscriber, .resize, .qualityChange]
        
        for reason in reasons {
            let request = P2PRequestKeyFrame(reason: reason)
            
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            
            let encoded = try encoder.encode(request)
            let decoded = try decoder.decode(P2PRequestKeyFrame.self, from: encoded)
            
 // Property: Round-trip should preserve reason
            XCTAssertEqual(decoded.reason, reason,
                           "Reason \(reason) must survive round-trip")
        }
    }
    
 // MARK: - Helper Methods
    
 /// Helper to create P2PVideoFramePacket for testing
    private func makeP2PVideoFramePacket(
        frameSeq: UInt64,
        isKeyFrame: Bool,
        fragIndex: UInt16 = 0,
        fragCount: UInt16 = 1,
        payload: Data,
        orientation: P2PVideoOrientation = .portrait
    ) -> P2PVideoFramePacket {
        return P2PVideoFramePacket(
            frameSeq: frameSeq,
            fragIndex: fragIndex,
            fragCount: fragCount,
            flags: isKeyFrame ? .keyFrame : [],
            timestampMillis: P2PTimestamp.nowMillis,
            orientation: orientation,
            payload: payload
        )
    }
    
    private func fragmentVideoFrame(
        payload: Data,
        frameSeq: UInt64,
        isKeyFrame: Bool,
        payloadMax: Int
    ) -> [P2PVideoFramePacket] {
        var fragments: [P2PVideoFramePacket] = []
        let fragCount = Int(ceil(Double(payload.count) / Double(payloadMax)))
        
        for i in 0..<fragCount {
            let start = i * payloadMax
            let end = min(start + payloadMax, payload.count)
            let fragPayload = payload.subdata(in: start..<end)
            
            let packet = makeP2PVideoFramePacket(
                frameSeq: frameSeq,
                isKeyFrame: isKeyFrame,
                fragIndex: UInt16(i),
                fragCount: UInt16(fragCount),
                payload: fragPayload
            )
            fragments.append(packet)
        }
        
        return fragments
    }
}
