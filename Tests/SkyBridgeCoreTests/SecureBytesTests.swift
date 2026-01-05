//
// SecureBytesTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for SecureBytes
// **Feature: tech-debt-cleanup, Property 3: SecureBytes Zeroization**
// **Validates: Requirements 2.6**
//

import XCTest
@testable import SkyBridgeCore

final class SecureBytesTests: XCTestCase {
    
 // MARK: - Property 3: SecureBytes Zeroization
    
 /// **Property 3: SecureBytes Zeroization**
 /// *For any* SecureBytes instance, when it is deallocated, the wipingFunction
 /// SHALL be called with the correct pointer and size.
 /// **Validates: Requirements 2.6**
 ///
 /// **注意**：不直接验证内存内容（不可靠），而是通过注入 wipingFunction 验证擦除路径被调用
    #if DEBUG
    func testProperty3_WipingFunctionCalledOnDeinit() {
        let tracker = SecureBytesWipeTracker()
        let originalWipingFunction = SecureBytes.wipingFunction
        SecureBytes.wipingFunction = tracker.makeWipingFunction()
        
        defer {
 // 恢复原始擦除函数
            SecureBytes.wipingFunction = originalWipingFunction
        }
        
 // 创建并立即释放 SecureBytes
        let testSize = 32
        autoreleasepool {
            let _ = SecureBytes(count: testSize)
        }
        
 // 验证擦除函数被调用
        XCTAssertEqual(tracker.wipeCount, 1, "Wiping function should be called once on deinit")
        XCTAssertEqual(tracker.lastWipedSize, testSize, "Wiped size should match allocated size")
    }
    
    func testProperty3_WipingFunctionCalledWithCorrectSize() {
        let tracker = SecureBytesWipeTracker()
        let originalWipingFunction = SecureBytes.wipingFunction
        SecureBytes.wipingFunction = tracker.makeWipingFunction()
        
        defer {
            SecureBytes.wipingFunction = originalWipingFunction
        }
        
 // 测试不同大小
        let sizes = [1, 16, 32, 64, 128, 256, 1024]
        
        for size in sizes {
            tracker.reset()
            autoreleasepool {
                let _ = SecureBytes(count: size)
            }
            XCTAssertEqual(tracker.wipeCount, 1, "Wiping function should be called for size \(size)")
            XCTAssertEqual(tracker.lastWipedSize, size, "Wiped size should be \(size)")
        }
    }
    
    func testProperty3_WipingFunctionCalledForDataInit() {
        let tracker = SecureBytesWipeTracker()
        let originalWipingFunction = SecureBytes.wipingFunction
        SecureBytes.wipingFunction = tracker.makeWipingFunction()
        
        defer {
            SecureBytes.wipingFunction = originalWipingFunction
        }
        
        let testData = Data(repeating: 0xAB, count: 64)
        autoreleasepool {
            let _ = SecureBytes(data: testData)
        }
        
        XCTAssertEqual(tracker.wipeCount, 1, "Wiping function should be called for Data init")
        XCTAssertEqual(tracker.lastWipedSize, testData.count, "Wiped size should match data size")
    }
    
    func testProperty3_ManualZeroizeCalled() {
        let tracker = SecureBytesWipeTracker()
        let originalWipingFunction = SecureBytes.wipingFunction
        SecureBytes.wipingFunction = tracker.makeWipingFunction()
        
        defer {
            SecureBytes.wipingFunction = originalWipingFunction
        }
        
        let secureBytes = SecureBytes(count: 32)
        
 // 手动擦除
        secureBytes.zeroize()
        
        XCTAssertEqual(tracker.wipeCount, 1, "Manual zeroize should call wiping function")
        XCTAssertEqual(tracker.lastWipedSize, 32, "Wiped size should be 32")
        
 // deinit 时会再次调用
        tracker.reset()
    }
    #endif
    
 // MARK: - Basic Functionality Tests
    
    func testSecureBytesInitWithCount() {
        let secureBytes = SecureBytes(count: 32)
        
        XCTAssertEqual(secureBytes.byteCount, 32)
        XCTAssertFalse(secureBytes.isEmpty)
        
 // 验证初始化为零
        let data = secureBytes.data
        XCTAssertEqual(data.count, 32)
        XCTAssertTrue(data.allSatisfy { $0 == 0 }, "Should be initialized to zeros")
    }
    
    func testSecureBytesInitWithData() {
        let testData = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let secureBytes = SecureBytes(data: testData)
        
        XCTAssertEqual(secureBytes.byteCount, 5)
        XCTAssertEqual(secureBytes.data, testData)
    }
    
    func testSecureBytesInitWithBytes() {
        let testBytes: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
        let secureBytes = SecureBytes(bytes: testBytes)
        
        XCTAssertEqual(secureBytes.byteCount, 4)
        XCTAssertEqual(secureBytes.data, Data(testBytes))
    }
    
    func testSecureBytesEmptyInit() {
        let secureBytes = SecureBytes(count: 0)
        
        XCTAssertEqual(secureBytes.byteCount, 0)
        XCTAssertTrue(secureBytes.isEmpty)
        XCTAssertEqual(secureBytes.data, Data())
    }
    
    func testSecureBytesEmptyDataInit() {
        let secureBytes = SecureBytes(data: Data())
        
        XCTAssertEqual(secureBytes.byteCount, 0)
        XCTAssertTrue(secureBytes.isEmpty)
    }
    
    func testSecureBytesWithUnsafeBytes() {
        let testData = Data([0x01, 0x02, 0x03, 0x04])
        let secureBytes = SecureBytes(data: testData)
        
        var sum: UInt8 = 0
        secureBytes.withUnsafeBytes { buffer in
            for byte in buffer {
                sum += byte
            }
        }
        
        XCTAssertEqual(sum, 0x01 + 0x02 + 0x03 + 0x04)
    }
    
    func testSecureBytesWithUnsafeMutableBytes() {
        let secureBytes = SecureBytes(count: 4)
        
        secureBytes.withUnsafeMutableBytes { buffer in
            buffer[0] = 0xAA
            buffer[1] = 0xBB
            buffer[2] = 0xCC
            buffer[3] = 0xDD
        }
        
        XCTAssertEqual(secureBytes.data, Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }
    
    func testSecureBytesDataCopyIndependence() {
        let secureBytes = SecureBytes(count: 4)
        
 // 修改 SecureBytes 内容
        secureBytes.withUnsafeMutableBytes { buffer in
            buffer[0] = 0x11
            buffer[1] = 0x22
            buffer[2] = 0x33
            buffer[3] = 0x44
        }
        
 // 获取 data 副本
        let dataCopy = secureBytes.data
        
 // 修改 SecureBytes
        secureBytes.withUnsafeMutableBytes { buffer in
            buffer[0] = 0xFF
        }
        
 // 验证 data 副本不受影响
        XCTAssertEqual(dataCopy[0], 0x11, "Data copy should be independent")
    }
    
    func testSecureBytesLargeAllocation() {
 // 测试较大的分配
        let largeSize = 1024 * 1024  // 1MB
        let secureBytes = SecureBytes(count: largeSize)
        
        XCTAssertEqual(secureBytes.byteCount, largeSize)
        
 // 验证可以访问
        secureBytes.withUnsafeBytes { buffer in
            XCTAssertEqual(buffer.count, largeSize)
        }
    }
    
    func testSecureBytesManualZeroize() {
        let testData = Data([0x01, 0x02, 0x03, 0x04])
        let secureBytes = SecureBytes(data: testData)
        
 // 手动擦除
        secureBytes.zeroize()
        
 // 验证内容被擦除
        let data = secureBytes.data
        XCTAssertTrue(data.allSatisfy { $0 == 0 }, "Should be zeroed after zeroize()")
    }
}
