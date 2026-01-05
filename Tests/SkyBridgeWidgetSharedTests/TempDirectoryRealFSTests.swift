// MARK: - Temp Directory Real FS Tests
// 使用临时目录的真实文件系统测试
// Requirements: 5.1

import Testing
import Foundation
import CryptoKit
@testable import SkyBridgeWidgetShared

@Suite("Temp Directory Real FS Tests")
struct TempDirectoryRealFSTests {
    
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    
 // MARK: - Real File System Tests
    
    @Test("RealFileSystem writes and reads data correctly")
    func testRealFileSystemWriteRead() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let fs = RealFileSystem()
        let fileURL = tempDir.appendingPathComponent("test.json")
        let testData = Data("Hello, World!".utf8)
        
 // Write
        try fs.write(testData, to: fileURL)
        
 // Verify file exists
        #expect(fs.fileExists(at: fileURL))
        
 // Read
        let readData = try fs.read(from: fileURL)
        
        #expect(readData == testData)
    }
    
    @Test("RealFileSystem atomic write behavior")
    func testAtomicWriteBehavior() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let fs = RealFileSystem()
        let fileURL = tempDir.appendingPathComponent("atomic_test.json")
        
 // Write initial data
        let initialData = Data("Initial".utf8)
        try fs.write(initialData, to: fileURL)
        
 // Write new data (should be atomic)
        let newData = Data("New Data".utf8)
        try fs.write(newData, to: fileURL)
        
 // Read should get new data
        let readData = try fs.read(from: fileURL)
        #expect(readData == newData)
    }
    
    @Test("RealFileSystem creates directory if needed")
    func testCreatesDirectoryIfNeeded() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nested")
            .appendingPathComponent("directory")
        defer { 
            try? FileManager.default.removeItem(
                at: FileManager.default.temporaryDirectory
                    .appendingPathComponent(tempDir.pathComponents[tempDir.pathComponents.count - 3])
            )
        }
        
        let fs = RealFileSystem()
        let fileURL = tempDir.appendingPathComponent("test.json")
        let testData = Data("Test".utf8)
        
 // Should create nested directories
        try fs.write(testData, to: fileURL)
        
        #expect(fs.fileExists(at: fileURL))
    }
    
    @Test("RealFileSystem fileExists returns false for non-existent file")
    func testFileExistsReturnsFalse() {
        let fs = RealFileSystem()
        let nonExistentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("does_not_exist.json")
        
        #expect(!fs.fileExists(at: nonExistentURL))
    }
    
    @Test("RealFileSystem read throws for non-existent file")
    func testReadThrowsForNonExistent() {
        let fs = RealFileSystem()
        let nonExistentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("does_not_exist.json")
        
        #expect(throws: Error.self) {
            _ = try fs.read(from: nonExistentURL)
        }
    }
    
 // MARK: - Widget Data Round Trip with Real FS
    
    @Test("WidgetDevicesData round trip through real file system")
    func testDevicesDataRealFSRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let fs = RealFileSystem()
        let fileURL = tempDir.appendingPathComponent("widget_devices.json")
        
 // Create test data
        let original = WidgetTestGenerators.devicesData(deviceCount: 10)
        
 // Encode and write
        let jsonData = try encoder.encode(original)
        try fs.write(jsonData, to: fileURL)
        
 // Read and decode
        let readData = try fs.read(from: fileURL)
        let decoded = try decoder.decode(WidgetDevicesData.self, from: readData)
        
 // Verify semantic equality
        #expect(decoded.semanticEquals(original))
    }
    
    @Test("SHA256 hash is consistent across write/read cycle")
    func testSHA256ConsistencyAcrossWriteRead() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let fs = RealFileSystem()
        let fileURL = tempDir.appendingPathComponent("hash_test.json")
        
        let original = WidgetTestGenerators.devicesData(deviceCount: 5)
        let jsonData = try encoder.encode(original)
        let originalHash = sha256String(jsonData)
        
 // Write to file
        try fs.write(jsonData, to: fileURL)
        
 // Read back
        let readData = try fs.read(from: fileURL)
        let readHash = sha256String(readData)
        
        #expect(originalHash == readHash, """
            SHA256 should be identical after write/read cycle
            Original: \(originalHash)
            After read: \(readHash)
            """)
    }
    
 // MARK: - InMemoryFileSystem Tests
    
    @Test("InMemoryFileSystem basic operations")
    func testInMemoryFileSystemBasic() throws {
        let fs = InMemoryFileSystem()
        let url = URL(fileURLWithPath: "/test/file.json")
        let testData = Data("Test".utf8)
        
 // Initially doesn't exist
        #expect(!fs.fileExists(at: url))
        
 // Write
        try fs.write(testData, to: url)
        
 // Now exists
        #expect(fs.fileExists(at: url))
        #expect(fs.fileCount == 1)
        
 // Read
        let readData = try fs.read(from: url)
        #expect(readData == testData)
        
 // Clear
        fs.clear()
        #expect(fs.fileCount == 0)
        #expect(!fs.fileExists(at: url))
    }
    
    @Test("InMemoryFileSystem writeCorrupted for fault injection")
    func testInMemoryFileSystemCorrupted() throws {
        let fs = InMemoryFileSystem()
        let url = URL(fileURLWithPath: "/test/corrupted.json")
        
        try fs.writeCorrupted(to: url)
        
        let data = try fs.read(from: url)
        
 // Should fail to decode
        #expect(throws: Error.self) {
            _ = try decoder.decode(WidgetDevicesData.self, from: data)
        }
    }
    
 // MARK: - Helper
    
    private func sha256String(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
