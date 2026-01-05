// BonjourServiceEnhancedTests.swift
// SkyBridgeCoreTests
//
// Bonjour 服务增强测试 - 包含属性测试
// Created for web-agent-integration spec 11

import Testing
import Foundation
@testable import SkyBridgeCore

// MARK: - Property Tests

/// **Feature: web-agent-integration, Property 4: TXT 记录完整性**
/// **Validates: Requirements 3.2**
@Suite("TXT Record Completeness Tests")
struct TXTRecordCompletenessTests {
    
    @Test("TXT 记录包含所有必需字段", arguments: (0..<20).map { _ in UUID().uuidString })
    func testTXTRecordContainsRequiredFields(deviceId: String) {
        guard #available(macOS 14.0, *) else { return }
        
        let pubKeyFP = generateRandomHexString(length: 64)
        let uniqueId = UUID().uuidString
        
        let builder = BonjourTXTRecordBuilder(
            deviceId: deviceId,
            pubKeyFP: pubKeyFP,
            uniqueId: uniqueId
        )
        
        let record = builder.build()
        
 // 验证必需字段存在
        #expect(record["deviceId"] == deviceId)
        #expect(record["pubKeyFP"] == pubKeyFP)
        #expect(record["uniqueId"] == uniqueId)
        
 // 验证通过验证器
        #expect(BonjourTXTRecordBuilder.validate(record) == true)
    }
    
    @Test("TXT 记录验证器正确检测缺失字段")
    func testTXTRecordValidatorDetectsMissingFields() {
        guard #available(macOS 14.0, *) else { return }
        
 // 缺少 deviceId
        let record1: [String: String] = [
            "pubKeyFP": "abc123",
            "uniqueId": "unique-1"
        ]
        let result1 = TXTRecordValidator.validate(record1)
        #expect(result1.isValid == false)
        
 // 缺少 pubKeyFP
        let record2: [String: String] = [
            "deviceId": "device-1",
            "uniqueId": "unique-1"
        ]
        let result2 = TXTRecordValidator.validate(record2)
        #expect(result2.isValid == false)
        
 // 缺少 uniqueId
        let record3: [String: String] = [
            "deviceId": "device-1",
            "pubKeyFP": "abc123"
        ]
        let result3 = TXTRecordValidator.validate(record3)
        #expect(result3.isValid == false)
        
 // 所有字段都存在
        let record4: [String: String] = [
            "deviceId": "device-1",
            "pubKeyFP": "abc123",
            "uniqueId": "unique-1"
        ]
        let result4 = TXTRecordValidator.validate(record4)
        #expect(result4.isValid == true)
    }
    
    @Test("TXT 记录验证器检测空值字段")
    func testTXTRecordValidatorDetectsEmptyFields() {
        guard #available(macOS 14.0, *) else { return }
        
 // deviceId 为空
        let record1: [String: String] = [
            "deviceId": "",
            "pubKeyFP": "abc123",
            "uniqueId": "unique-1"
        ]
        let result1 = TXTRecordValidator.validate(record1)
        #expect(result1.isValid == false)
    }
    
    @Test("TXT 记录验证器检测 pubKeyFP 格式")
    func testTXTRecordValidatorChecksPubKeyFPFormat() {
        guard #available(macOS 14.0, *) else { return }
        
 // 有效的 hex 小写格式
        let record1: [String: String] = [
            "deviceId": "device-1",
            "pubKeyFP": "abc123def456",
            "uniqueId": "unique-1"
        ]
        let result1 = TXTRecordValidator.validate(record1)
        #expect(result1.isValid == true)
        
 // 无效格式（包含大写）
        let record2: [String: String] = [
            "deviceId": "device-1",
            "pubKeyFP": "ABC123DEF456",
            "uniqueId": "unique-1"
        ]
        let result2 = TXTRecordValidator.validate(record2)
        #expect(result2.isValid == false)
        
 // 无效格式（包含非 hex 字符）
        let record3: [String: String] = [
            "deviceId": "device-1",
            "pubKeyFP": "xyz123",
            "uniqueId": "unique-1"
        ]
        let result3 = TXTRecordValidator.validate(record3)
        #expect(result3.isValid == false)
    }
    
 /// 生成随机 hex 字符串
    private func generateRandomHexString(length: Int) -> String {
        let hexChars = "0123456789abcdef"
        return String((0..<length).map { _ in hexChars.randomElement()! })
    }
}

// MARK: - TXT Record Builder Tests

@Suite("TXT Record Builder Tests")
struct TXTRecordBuilderTests {
    
    @Test("构建器正确设置可选字段")
    func testBuilderSetsOptionalFields() {
        guard #available(macOS 14.0, *) else { return }
        
        let builder = BonjourTXTRecordBuilder(
            deviceId: "device-1",
            pubKeyFP: "abc123",
            uniqueId: "unique-1",
            platform: "macos",
            version: "1.0.0",
            capabilities: ["remote_desktop", "file_transfer"],
            name: "My Mac"
        )
        
        let record = builder.build()
        
        #expect(record["platform"] == "macos")
        #expect(record["version"] == "1.0.0")
        #expect(record["capabilities"] == "remote_desktop,file_transfer")
        #expect(record["name"] == "My Mac")
    }
    
    @Test("构建器正确编码为数据格式")
    func testBuilderEncodesToData() {
        guard #available(macOS 14.0, *) else { return }
        
        let builder = BonjourTXTRecordBuilder(
            deviceId: "device-1",
            pubKeyFP: "abc123",
            uniqueId: "unique-1"
        )
        
        let data = builder.buildData()
        
 // 数据不应为空
        #expect(!data.isEmpty)
        
 // 验证数据格式（每个条目以长度字节开头）
        var index = data.startIndex
        var entries: [String] = []
        
        while index < data.endIndex {
            let length = Int(data[index])
            index = data.index(after: index)
            
            guard index.advanced(by: length) <= data.endIndex else { break }
            
            let entryData = data[index..<index.advanced(by: length)]
            if let entry = String(data: entryData, encoding: .utf8) {
                entries.append(entry)
            }
            
            index = index.advanced(by: length)
        }
        
 // 应该有 3 个条目（deviceId, pubKeyFP, uniqueId）
        #expect(entries.count == 3)
        
 // 验证条目格式
        for entry in entries {
            #expect(entry.contains("="))
        }
    }
    
    @Test("从设备能力创建构建器")
    func testBuilderFromDeviceCapabilities() {
        guard #available(macOS 14.0, *) else { return }
        
        let capabilities: SBDeviceCapabilities = [.remoteDesktop, .fileTransfer, .screenSharing]
        
        let builder = BonjourTXTRecordBuilder.from(
            deviceId: "device-1",
            pubKeyFP: "abc123",
            uniqueId: "unique-1",
            capabilities: capabilities
        )
        
        let record = builder.build()
        
        #expect(record["deviceId"] == "device-1")
        #expect(record["platform"] == SBPlatformType.current.rawValue)
        #expect(record["version"] == SBProtocolVersion.current.versionString)
        
 // 验证能力字段
        if let capsString = record["capabilities"] {
            let caps = capsString.split(separator: ",").map(String.init)
            #expect(caps.contains("remote_desktop"))
            #expect(caps.contains("file_transfer"))
            #expect(caps.contains("screen_sharing"))
        }
    }
}

// MARK: - Enhanced Bonjour Service Tests

@Suite("Enhanced Bonjour Service Tests")
struct EnhancedBonjourServiceTests {
    
    @Test("服务初始化")
    func testServiceInitialization() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = EnhancedBonjourService(
            serviceType: "_skybridge._tcp",
            maxRetries: 3,
            retryDelay: 10.0
        )
        
        let isRegistered = await service.isServiceRegistered
        #expect(isRegistered == false)
        
        let port = await service.assignedPort
        #expect(port == 0)
    }
    
    @Test("TXT 记录验证失败时抛出错误")
    func testInvalidTXTRecordThrowsError() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = EnhancedBonjourService()
        
 // 创建无效的 TXT 记录（缺少必需字段）
        let invalidBuilder = BonjourTXTRecordBuilder(
            deviceId: "",  // 空的 deviceId
            pubKeyFP: "abc123",
            uniqueId: "unique-1"
        )
        
        do {
            _ = try await service.register(
                name: "Test Service",
                txtRecord: invalidBuilder
            )
            Issue.record("应该抛出错误")
        } catch let error as BonjourServiceError {
            if case .invalidTXTRecord = error {
 // 预期行为
            } else {
                Issue.record("错误类型不正确: \(error)")
            }
        } catch {
            Issue.record("未预期的错误类型: \(error)")
        }
    }
}

// MARK: - Round-Trip Tests

@Suite("TXT Record Round-Trip Tests")
struct TXTRecordRoundTripTests {
    
    @Test("TXT 记录编码/解码 Round-Trip", arguments: (0..<10).map { _ in UUID().uuidString })
    func testTXTRecordRoundTrip(deviceId: String) {
        guard #available(macOS 14.0, *) else { return }
        
        let original: [String: String] = [
            "deviceId": deviceId,
            "pubKeyFP": "abc123def456",
            "uniqueId": UUID().uuidString,
            "platform": "macos",
            "version": "1.0.0"
        ]
        
 // 编码
        let data = BonjourTXTRecordBuilder.encodeToData(original)
        
 // 解码
        let decoded = BonjourTXTParser.parseRawTXTData(data)
        
 // 验证 Round-Trip
        for (key, value) in original {
            #expect(decoded[key] == value)
        }
    }
}
