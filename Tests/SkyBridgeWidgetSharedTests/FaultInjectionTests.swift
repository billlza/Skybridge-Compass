// MARK: - Fault Injection Tests
// 故障注入测试 - 验证坏数据时回退 lastGoodData
// Requirements: 5.4

import Testing
import Foundation
@testable import SkyBridgeWidgetShared

@Suite("Fault Injection Tests")
struct FaultInjectionTests {
    
 // MARK: - Corrupted JSON Tests
    
    @Test("Reader returns lastGoodData when JSON is corrupted")
    func testCorruptedJSONFallback() throws {
        let fs = InMemoryFileSystem()
        let tempURL = URL(fileURLWithPath: "/test")
        let reader = WidgetDataReader(fileSystem: fs, containerURL: tempURL)
        
 // 1. Write valid data first
        let validData = WidgetTestGenerators.devicesData(deviceCount: 5)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validJSON = try encoder.encode(validData)
        let fileURL = tempURL.appendingPathComponent(WidgetDataLimits.devicesFileName)
        try fs.write(validJSON, to: fileURL)
        
 // 2. Read to populate lastGoodData
        let firstRead = reader.loadDevicesData()
        #expect(firstRead != nil)
        #expect(firstRead?.devices.count == 5)
        
 // 3. Write corrupted JSON
        try fs.writeCorrupted(to: fileURL)
        
 // 4. Read should return lastGoodData, not nil
        let secondRead = reader.loadDevicesData()
        #expect(secondRead != nil, "Should return lastGoodData when JSON is corrupted")
        #expect(secondRead?.devices.count == 5, "Should return the cached valid data")
    }
    
    @Test("Reader returns lastGoodData when file is truncated")
    func testTruncatedFileFallback() throws {
        let fs = InMemoryFileSystem()
        let tempURL = URL(fileURLWithPath: "/test")
        let reader = WidgetDataReader(fileSystem: fs, containerURL: tempURL)
        
 // 1. Write valid data
        let validData = WidgetTestGenerators.metricsData()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validJSON = try encoder.encode(validData)
        let fileURL = tempURL.appendingPathComponent(WidgetDataLimits.metricsFileName)
        try fs.write(validJSON, to: fileURL)
        
 // 2. Read to populate cache
        _ = reader.loadMetricsData()
        
 // 3. Write truncated data (first half of valid JSON)
        let truncatedData = validJSON.prefix(validJSON.count / 2)
        try fs.write(Data(truncatedData), to: fileURL)
        
 // 4. Read should return lastGoodData
        let result = reader.loadMetricsData()
        #expect(result != nil, "Should return lastGoodData when file is truncated")
    }
    
    @Test("Reader returns lastGoodData when file contains invalid JSON type")
    func testInvalidJSONTypeFallback() throws {
        let fs = InMemoryFileSystem()
        let tempURL = URL(fileURLWithPath: "/test")
        let reader = WidgetDataReader(fileSystem: fs, containerURL: tempURL)
        
 // 1. Write valid data
        let validData = WidgetTestGenerators.transfersData(transferCount: 3)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validJSON = try encoder.encode(validData)
        let fileURL = tempURL.appendingPathComponent(WidgetDataLimits.transfersFileName)
        try fs.write(validJSON, to: fileURL)
        
 // 2. Read to populate cache
        _ = reader.loadTransfersData()
        
 // 3. Write valid JSON but wrong type (array instead of object)
        let wrongTypeJSON = Data("[1, 2, 3]".utf8)
        try fs.write(wrongTypeJSON, to: fileURL)
        
 // 4. Read should return lastGoodData
        let result = reader.loadTransfersData()
        #expect(result != nil, "Should return lastGoodData when JSON type is wrong")
        #expect(result?.transfers.count == 3)
    }
    
 // MARK: - Missing File Tests
    
    @Test("Reader returns nil when file doesn't exist and no cache")
    func testMissingFileNoCache() {
        let fs = InMemoryFileSystem()
        let tempURL = URL(fileURLWithPath: "/test")
        let reader = WidgetDataReader(fileSystem: fs, containerURL: tempURL)
        
 // No file written, no cache
        let result = reader.loadDevicesData()
        #expect(result == nil, "Should return nil when no file and no cache")
    }
    
    @Test("Reader returns lastGoodData when file is deleted")
    func testDeletedFileFallback() throws {
        let fs = InMemoryFileSystem()
        let tempURL = URL(fileURLWithPath: "/test")
        let reader = WidgetDataReader(fileSystem: fs, containerURL: tempURL)
        
 // 1. Write valid data
        let validData = WidgetTestGenerators.devicesData(deviceCount: 3)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validJSON = try encoder.encode(validData)
        let fileURL = tempURL.appendingPathComponent(WidgetDataLimits.devicesFileName)
        try fs.write(validJSON, to: fileURL)
        
 // 2. Read to populate cache
        _ = reader.loadDevicesData()
        
 // 3. "Delete" file by clearing storage
        fs.clear()
        
 // 4. Read should return lastGoodData
        let result = reader.loadDevicesData()
        #expect(result != nil, "Should return lastGoodData when file is deleted")
        #expect(result?.devices.count == 3)
    }
    
 // MARK: - Container Unavailable Tests
    
    @Test("Reader returns lastGoodData when container is unavailable")
    func testContainerUnavailableFallback() throws {
        let fs = InMemoryFileSystem()
        let reader = WidgetDataReader(fileSystem: fs, containerURL: nil)
        
 // Pre-set lastGoodData
        let validData = WidgetTestGenerators.devicesData(deviceCount: 7)
        reader.setLastGoodDevicesData(validData)
        
 // Read should return lastGoodData since container is nil
        let result = reader.loadDevicesData()
        #expect(result != nil)
        #expect(result?.devices.count == 7)
    }
    
 // MARK: - Cache Clear Tests
    
    @Test("clearCache removes all cached data")
    func testClearCache() throws {
        let fs = InMemoryFileSystem()
        let tempURL = URL(fileURLWithPath: "/test")
        let reader = WidgetDataReader(fileSystem: fs, containerURL: tempURL)
        
 // Pre-set caches
        reader.setLastGoodDevicesData(WidgetTestGenerators.devicesData(deviceCount: 5))
        reader.setLastGoodMetricsData(WidgetTestGenerators.metricsData())
        reader.setLastGoodTransfersData(WidgetTestGenerators.transfersData(transferCount: 3))
        
 // Clear cache
        reader.clearCache()
        
 // All reads should return nil (no file, no cache)
        #expect(reader.loadDevicesData() == nil)
        #expect(reader.loadMetricsData() == nil)
        #expect(reader.loadTransfersData() == nil)
    }
    
 // MARK: - Concurrent Access Tests
    
    @Test("Reader handles concurrent reads safely")
    func testConcurrentReads() async throws {
        let fs = InMemoryFileSystem()
        let tempURL = URL(fileURLWithPath: "/test")
        let reader = WidgetDataReader(fileSystem: fs, containerURL: tempURL)
        
 // Write valid data
        let validData = WidgetTestGenerators.devicesData(deviceCount: 10)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validJSON = try encoder.encode(validData)
        let fileURL = tempURL.appendingPathComponent(WidgetDataLimits.devicesFileName)
        try fs.write(validJSON, to: fileURL)
        
 // Concurrent reads
        await withTaskGroup(of: WidgetDevicesData?.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    reader.loadDevicesData()
                }
            }
            
            var results: [WidgetDevicesData?] = []
            for await result in group {
                results.append(result)
            }
            
 // All reads should succeed
            #expect(results.allSatisfy { $0 != nil })
            #expect(results.allSatisfy { $0?.devices.count == 10 })
        }
    }
}
