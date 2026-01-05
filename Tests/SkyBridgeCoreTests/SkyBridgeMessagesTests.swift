//
// SkyBridgeMessagesTests.swift
// SkyBridgeCoreTests
//
// SkyBridge Protocol 消息序列化测试
//
// **Feature: web-agent-integration, Property 1: 信令消息序列化 Round-Trip**
// **Validates: Requirements 2.6, 2.7**
//

import Testing
import Foundation
@testable import SkyBridgeCore

// MARK: - Property Test Configuration

private struct PropertyTestConfig {
    static let iterations = 100
}

// MARK: - Random Data Generators

private enum RandomGenerator {
    
    static func randomString(length: Int = 32) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        return String((0..<length).map { _ in chars.randomElement()! })
    }
    
    static func randomUUID() -> String {
        UUID().uuidString
    }
    
    static func randomSDP() -> String {
        """
        v=0
        o=- \(Int.random(in: 1000000...9999999)) 2 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0
        m=application 9 UDP/DTLS/SCTP webrtc-datachannel
        c=IN IP4 0.0.0.0
        a=ice-ufrag:\(randomString(length: 8))
        a=ice-pwd:\(randomString(length: 24))
        a=fingerprint:sha-256 \(randomString(length: 64))
        """
    }
    
    static func randomICECandidate() -> String {
        "candidate:\(Int.random(in: 1...999)) 1 udp \(Int.random(in: 1000000...9999999)) 192.168.1.\(Int.random(in: 1...254)) \(Int.random(in: 10000...65535)) typ host"
    }
    
    static func randomIP() -> String {
        "\(Int.random(in: 1...255)).\(Int.random(in: 0...255)).\(Int.random(in: 0...255)).\(Int.random(in: 1...254))"
    }
}


// MARK: - Property Tests: Round-Trip Serialization

/// **Feature: web-agent-integration, Property 1: 信令消息序列化 Round-Trip**
/// **Validates: Requirements 2.6, 2.7**
@Suite("SkyBridge Messages Round-Trip Tests")
struct SkyBridgeMessagesRoundTripTests {
    
 // MARK: - AuthMessage Round-Trip
    
    @Test("AuthMessage 序列化 Round-Trip", arguments: (0..<PropertyTestConfig.iterations).map { _ in RandomGenerator.randomString() })
    func testAuthMessageRoundTrip(token: String) throws {
        let original = AuthMessage(token: token)
        let encoded = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(AuthMessage.self, from: encoded)
        
        #expect(original == decoded)
        #expect(original.type == decoded.type)
        #expect(original.token == decoded.token)
    }
    
 // MARK: - AuthOKMessage Round-Trip
    
    @Test("AuthOKMessage 序列化 Round-Trip", arguments: (0..<PropertyTestConfig.iterations).map { _ in RandomGenerator.randomString() })
    func testAuthOKMessageRoundTrip(message: String) throws {
        let original = AuthOKMessage(message: message)
        let encoded = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(AuthOKMessage.self, from: encoded)
        
        #expect(original == decoded)
        #expect(original.type == decoded.type)
        #expect(original.message == decoded.message)
    }
    
 // MARK: - SessionJoinMessage Round-Trip
    
    @Test("SessionJoinMessage 序列化 Round-Trip")
    func testSessionJoinMessageRoundTrip() throws {
        for _ in 0..<PropertyTestConfig.iterations {
            let original = SessionJoinMessage(
                sessionId: RandomGenerator.randomUUID(),
                deviceId: RandomGenerator.randomUUID()
            )
            let encoded = try SkyBridgeMessageCodec.encode(original)
            let decoded = try SkyBridgeMessageCodec.decode(SessionJoinMessage.self, from: encoded)
            
            #expect(original == decoded)
            #expect(original.sessionId == decoded.sessionId)
            #expect(original.deviceId == decoded.deviceId)
        }
    }
    
 // MARK: - SDPOfferMessage Round-Trip
    
    @Test("SDPOfferMessage 序列化 Round-Trip")
    func testSDPOfferMessageRoundTrip() throws {
        for _ in 0..<PropertyTestConfig.iterations {
            let original = SDPOfferMessage(
                sessionId: RandomGenerator.randomUUID(),
                deviceId: RandomGenerator.randomUUID(),
                authToken: RandomGenerator.randomString(),
                offer: SDPDescription(type: "offer", sdp: RandomGenerator.randomSDP())
            )
            let encoded = try SkyBridgeMessageCodec.encode(original)
            let decoded = try SkyBridgeMessageCodec.decode(SDPOfferMessage.self, from: encoded)
            
            #expect(original == decoded)
            #expect(original.offer.type == decoded.offer.type)
            #expect(original.offer.sdp == decoded.offer.sdp)
        }
    }
    
 // MARK: - SDPAnswerMessage Round-Trip
    
    @Test("SDPAnswerMessage 序列化 Round-Trip")
    func testSDPAnswerMessageRoundTrip() throws {
        for _ in 0..<PropertyTestConfig.iterations {
            let original = SDPAnswerMessage(
                sessionId: RandomGenerator.randomUUID(),
                deviceId: RandomGenerator.randomUUID(),
                authToken: RandomGenerator.randomString(),
                answer: SDPDescription(type: "answer", sdp: RandomGenerator.randomSDP())
            )
            let encoded = try SkyBridgeMessageCodec.encode(original)
            let decoded = try SkyBridgeMessageCodec.decode(SDPAnswerMessage.self, from: encoded)
            
            #expect(original == decoded)
            #expect(original.answer.type == decoded.answer.type)
            #expect(original.answer.sdp == decoded.answer.sdp)
        }
    }
    
 // MARK: - SBICECandidateMessage Round-Trip
    
    @Test("SBICECandidateMessage 序列化 Round-Trip")
    func testICECandidateMessageRoundTrip() throws {
        for _ in 0..<PropertyTestConfig.iterations {
            let original = SBICECandidateMessage(
                sessionId: RandomGenerator.randomUUID(),
                deviceId: RandomGenerator.randomUUID(),
                authToken: RandomGenerator.randomString(),
                candidate: SBICECandidate(
                    candidate: RandomGenerator.randomICECandidate(),
                    sdpMid: Bool.random() ? "0" : nil,
                    sdpMLineIndex: Bool.random() ? Int.random(in: 0...3) : nil
                )
            )
            let encoded = try SkyBridgeMessageCodec.encode(original)
            let decoded = try SkyBridgeMessageCodec.decode(SBICECandidateMessage.self, from: encoded)
            
            #expect(original == decoded)
            #expect(original.candidate.candidate == decoded.candidate.candidate)
            #expect(original.candidate.sdpMid == decoded.candidate.sdpMid)
            #expect(original.candidate.sdpMLineIndex == decoded.candidate.sdpMLineIndex)
        }
    }
}


// MARK: - SBDevicesMessage Round-Trip

@Suite("SBDevicesMessage Round-Trip Tests")
struct SBDevicesMessageRoundTripTests {
    
    @Test("SBDevicesMessage 序列化 Round-Trip")
    func testDevicesMessageRoundTrip() throws {
        for _ in 0..<PropertyTestConfig.iterations {
            let deviceCount = Int.random(in: 0...10)
            let devices = (0..<deviceCount).map { _ in
                SBDeviceInfo(
                    id: RandomGenerator.randomUUID(),
                    name: RandomGenerator.randomString(length: 16),
                    ipv4: Bool.random() ? RandomGenerator.randomIP() : nil,
                    ipv6: nil,
                    services: ["_skybridge._tcp"],
                    portMap: ["skybridge": Int.random(in: 7000...8000)],
                    connectionTypes: ["lan"],
                    source: "bonjour",
                    isLocalDevice: Bool.random(),
                    deviceId: RandomGenerator.randomUUID(),
                    pubKeyFP: RandomGenerator.randomString(length: 64)
                )
            }
            
            let original = SBDevicesMessage(devices: devices)
            let encoded = try SkyBridgeMessageCodec.encode(original)
            let decoded = try SkyBridgeMessageCodec.decode(SBDevicesMessage.self, from: encoded)
            
            #expect(original == decoded)
            #expect(original.devices.count == decoded.devices.count)
            
            for (orig, dec) in zip(original.devices, decoded.devices) {
                #expect(orig.id == dec.id)
                #expect(orig.name == dec.name)
                #expect(orig.ipv4 == dec.ipv4)
                #expect(orig.deviceId == dec.deviceId)
                #expect(orig.pubKeyFP == dec.pubKeyFP)
            }
        }
    }
}

// MARK: - FileTransfer Messages Round-Trip

@Suite("FileTransfer Messages Round-Trip Tests")
struct FileTransferMessagesRoundTripTests {
    
    @Test("FileMetaMessage 序列化 Round-Trip")
    func testFileMetaMessageRoundTrip() throws {
        for _ in 0..<PropertyTestConfig.iterations {
            let original = FileMetaMessage(
                fileId: RandomGenerator.randomUUID(),
                fileName: "\(RandomGenerator.randomString(length: 8)).\(["txt", "pdf", "jpg", "png"].randomElement()!)",
                fileSize: Int64.random(in: 0...Int64.max),
                mimeType: Bool.random() ? "application/octet-stream" : nil,
                checksum: Bool.random() ? RandomGenerator.randomString(length: 64) : nil
            )
            let encoded = try SkyBridgeMessageCodec.encode(original)
            let decoded = try SkyBridgeMessageCodec.decode(FileMetaMessage.self, from: encoded)
            
            #expect(original == decoded)
            #expect(original.fileId == decoded.fileId)
            #expect(original.fileName == decoded.fileName)
            #expect(original.fileSize == decoded.fileSize)
            #expect(original.mimeType == decoded.mimeType)
            #expect(original.checksum == decoded.checksum)
        }
    }
    
    @Test("FileAckMetaMessage 序列化 Round-Trip")
    func testFileAckMetaMessageRoundTrip() throws {
        for _ in 0..<PropertyTestConfig.iterations {
            let original = FileAckMetaMessage(
                fileId: RandomGenerator.randomUUID(),
                accepted: Bool.random(),
                reason: Bool.random() ? RandomGenerator.randomString() : nil
            )
            let encoded = try SkyBridgeMessageCodec.encode(original)
            let decoded = try SkyBridgeMessageCodec.decode(FileAckMetaMessage.self, from: encoded)
            
            #expect(original == decoded)
            #expect(original.fileId == decoded.fileId)
            #expect(original.accepted == decoded.accepted)
            #expect(original.reason == decoded.reason)
        }
    }
    
    @Test("FileEndMessage 序列化 Round-Trip")
    func testFileEndMessageRoundTrip() throws {
        for _ in 0..<PropertyTestConfig.iterations {
            let original = FileEndMessage(
                fileId: RandomGenerator.randomUUID(),
                success: Bool.random(),
                bytesTransferred: Int64.random(in: 0...Int64.max)
            )
            let encoded = try SkyBridgeMessageCodec.encode(original)
            let decoded = try SkyBridgeMessageCodec.decode(FileEndMessage.self, from: encoded)
            
            #expect(original == decoded)
            #expect(original.fileId == decoded.fileId)
            #expect(original.success == decoded.success)
            #expect(original.bytesTransferred == decoded.bytesTransferred)
        }
    }
}

// MARK: - Message Type Extraction Tests

@Suite("Message Type Extraction Tests")
struct MessageTypeExtractionTests {
    
    @Test("正确提取消息类型")
    func testExtractMessageType() throws {
        let authMessage = AuthMessage(token: "test")
        let authData = try SkyBridgeMessageCodec.encode(authMessage)
        let authType = try SkyBridgeMessageCodec.extractMessageType(from: authData)
        #expect(authType == .auth)
        
        let authOKMessage = AuthOKMessage(message: "ok")
        let authOKData = try SkyBridgeMessageCodec.encode(authOKMessage)
        let authOKType = try SkyBridgeMessageCodec.extractMessageType(from: authOKData)
        #expect(authOKType == .authOK)
        
        let sessionJoinMessage = SessionJoinMessage(sessionId: "s1", deviceId: "d1")
        let sessionJoinData = try SkyBridgeMessageCodec.encode(sessionJoinMessage)
        let sessionJoinType = try SkyBridgeMessageCodec.extractMessageType(from: sessionJoinData)
        #expect(sessionJoinType == .sessionJoin)
    }
    
    @Test("未知消息类型抛出错误")
    func testUnknownMessageType() throws {
        let unknownJSON = #"{"type": "unknown-type", "data": "test"}"#
        let data = unknownJSON.utf8Data
        
        #expect(throws: SkyBridgeMessageError.self) {
            _ = try SkyBridgeMessageCodec.extractMessageType(from: data)
        }
    }
}


// MARK: - Capability Negotiation Property Tests

/// **Feature: web-agent-integration, Property 11: 能力协商交集正确性**
/// **Validates: Requirements 9.5**
@Suite("Capability Negotiation Tests")
struct CapabilityNegotiationTests {
    
    @Test("能力协商返回交集")
    func testCapabilityNegotiationIntersection() {
        for _ in 0..<PropertyTestConfig.iterations {
 // 生成随机能力集合
            let allCaps: [SBDeviceCapabilities] = [
                .remoteDesktop, .fileTransfer, .screenSharing,
                .inputInjection, .systemControl, .pqcEncryption,
                .hybridEncryption, .audioTransfer, .clipboardSync
            ]
            
            var localCaps = SBDeviceCapabilities()
            var remoteCaps = SBDeviceCapabilities()
            
            for cap in allCaps {
                if Bool.random() { localCaps.insert(cap) }
                if Bool.random() { remoteCaps.insert(cap) }
            }
            
 // 执行协商
            let negotiated = SBCapabilityNegotiator.negotiate(local: localCaps, remote: remoteCaps)
            
 // 验证结果是交集
            let expected = localCaps.intersection(remoteCaps)
            #expect(negotiated == expected)
            
 // 验证协商结果是两个集合的子集
            #expect(negotiated.isSubset(of: localCaps))
            #expect(negotiated.isSubset(of: remoteCaps))
        }
    }
    
    @Test("字符串能力协商返回交集")
    func testStringCapabilityNegotiationIntersection() {
        for _ in 0..<PropertyTestConfig.iterations {
            let allCaps = [
                "remote_desktop", "file_transfer", "screen_sharing",
                "input_injection", "system_control", "pqc_encryption",
                "hybrid_encryption", "audio_transfer", "clipboard_sync"
            ]
            
            let localCaps = allCaps.filter { _ in Bool.random() }
            let remoteCaps = allCaps.filter { _ in Bool.random() }
            
            let negotiated = SBCapabilityNegotiator.negotiate(local: localCaps, remote: remoteCaps)
            
            let localSet = Set(localCaps)
            let remoteSet = Set(remoteCaps)
            let expected = localSet.intersection(remoteSet)
            
            #expect(Set(negotiated) == expected)
        }
    }
    
    @Test("加密模式协商选择最高安全级别")
    func testEncryptionModeNegotiation() {
 // 测试所有组合
        let allModes: [SBEncryptionMode] = [.classic, .pqc, .hybrid]
        
        for _ in 0..<PropertyTestConfig.iterations {
            let localModes = allModes.filter { _ in Bool.random() }
            let remoteModes = allModes.filter { _ in Bool.random() }
            
            guard !localModes.isEmpty && !remoteModes.isEmpty else { continue }
            
            let negotiated = SBCapabilityNegotiator.negotiateEncryptionMode(
                local: localModes,
                remote: remoteModes
            )
            
            let localSet = Set(localModes)
            let remoteSet = Set(remoteModes)
            let common = localSet.intersection(remoteSet)
            
            if common.isEmpty {
                #expect(negotiated == nil)
            } else {
                #expect(negotiated != nil)
 // 验证选择了最高安全级别
                let maxLevel = common.map { $0.securityLevel }.max()!
                #expect(negotiated!.securityLevel == maxLevel)
            }
        }
    }
    
    @Test("协议版本兼容性检查")
    func testProtocolVersionCompatibility() {
        let v1_0_0 = SBProtocolVersion(major: 1, minor: 0, patch: 0)
        let v1_1_0 = SBProtocolVersion(major: 1, minor: 1, patch: 0)
        let v1_0_1 = SBProtocolVersion(major: 1, minor: 0, patch: 1)
        let v2_0_0 = SBProtocolVersion(major: 2, minor: 0, patch: 0)
        
 // 同主版本号兼容
        #expect(v1_0_0.isCompatible(with: v1_1_0))
        #expect(v1_0_0.isCompatible(with: v1_0_1))
        #expect(v1_1_0.isCompatible(with: v1_0_0))
        
 // 不同主版本号不兼容
        #expect(!v1_0_0.isCompatible(with: v2_0_0))
        #expect(!v2_0_0.isCompatible(with: v1_0_0))
    }
    
    @Test("协议版本比较")
    func testProtocolVersionComparison() {
        let v1_0_0 = SBProtocolVersion(major: 1, minor: 0, patch: 0)
        let v1_1_0 = SBProtocolVersion(major: 1, minor: 1, patch: 0)
        let v1_0_1 = SBProtocolVersion(major: 1, minor: 0, patch: 1)
        let v2_0_0 = SBProtocolVersion(major: 2, minor: 0, patch: 0)
        
        #expect(v1_0_0 < v1_0_1)
        #expect(v1_0_1 < v1_1_0)
        #expect(v1_1_0 < v2_0_0)
        #expect(v1_0_0 == v1_0_0)
    }
    
    @Test("能力字符串转换 Round-Trip")
    func testCapabilityStringConversionRoundTrip() {
        for _ in 0..<PropertyTestConfig.iterations {
            let allCaps: [SBDeviceCapabilities] = [
                .remoteDesktop, .fileTransfer, .screenSharing,
                .inputInjection, .systemControl, .pqcEncryption,
                .hybridEncryption, .audioTransfer, .clipboardSync
            ]
            
            var original = SBDeviceCapabilities()
            for cap in allCaps {
                if Bool.random() { original.insert(cap) }
            }
            
 // 转换为字符串数组再转回来
            let strings = original.asStringArray
            let restored = SBDeviceCapabilities.from(strings: strings)
            
            #expect(original == restored)
        }
    }
}
