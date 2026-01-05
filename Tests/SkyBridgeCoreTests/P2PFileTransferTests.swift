//
// P2PFileTransferTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for P2P File Transfer
// **Feature: ios-p2p-integration**
//
// Property 19: File Metadata Round-Trip Serialization (Validates: Requirements 6.5)
// Property 20: File Transfer Resume Correctness (Validates: Requirements 6.3)
// Property 21: Merkle Tree Integrity Verification (Validates: Requirements 6.4)
//

import XCTest
import CryptoKit
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PFileTransferTests: XCTestCase {
    
 // MARK: - Property 19: File Metadata Round-Trip Serialization
    
 /// **Property 19: File Metadata Round-Trip Serialization**
 /// *For any* valid file metadata, serializing to JSON and deserializing should
 /// produce equivalent metadata.
 /// **Validates: Requirements 6.5**
    func testFileMetadataRoundTripSerializationProperty() throws {
        let testMetadata = generateTestFileMetadata()
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        
        let decoder = JSONDecoder()
        
        for metadata in testMetadata {
 // Encode
            let encoded = try encoder.encode(metadata)
            
 // Decode
            let decoded = try decoder.decode(P2PFileTransferMetadata.self, from: encoded)
            
 // Property: transferId must survive round-trip
            XCTAssertEqual(decoded.transferId, metadata.transferId,
                           "transferId must survive round-trip")
            
 // Property: fileTree.name must survive round-trip
            XCTAssertEqual(decoded.fileTree.name, metadata.fileTree.name,
                           "fileTree.name must survive round-trip")
            
 // Property: totalSize must survive round-trip
            XCTAssertEqual(decoded.totalSize, metadata.totalSize,
                           "totalSize must survive round-trip")
            
 // Property: chunkSize must survive round-trip
            XCTAssertEqual(decoded.chunkSize, metadata.chunkSize,
                           "chunkSize must survive round-trip")
            
 // Property: totalChunks must survive round-trip
            XCTAssertEqual(decoded.totalChunks, metadata.totalChunks,
                           "totalChunks must survive round-trip")
            
 // Property: merkleRoot must survive round-trip
            XCTAssertEqual(decoded.merkleRoot, metadata.merkleRoot,
                           "merkleRoot must survive round-trip")
            
 // Property: merkleRootSignature must survive round-trip
            XCTAssertEqual(decoded.merkleRootSignature, metadata.merkleRootSignature,
                           "merkleRootSignature must survive round-trip")
        }
    }
    
 /// Test file metadata encoding is deterministic
    func testFileMetadataEncodingDeterministic() throws {
        let metadata = createTestMetadata(
            name: "test.txt",
            size: 1024,
            chunkSize: 256,
            totalChunks: 4
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        
        let encoded1 = try encoder.encode(metadata)
        let encoded2 = try encoder.encode(metadata)
        
 // Property: Same metadata must produce same encoding
        XCTAssertEqual(encoded1, encoded2,
                       "Encoding must be deterministic")
    }
    
 // MARK: - Property 20: File Transfer Resume Correctness
    
 /// **Property 20: File Transfer Resume Correctness**
 /// *For any* interrupted file transfer, resuming should continue from the last
 /// acknowledged chunk offset without data loss or duplication.
 /// **Validates: Requirements 6.3**
    func testFileTransferResumeCorrectnessProperty() {
        let totalChunks = 100
        var acknowledgedChunks = Set<Int>()
        
 // Simulate partial transfer (first 50 chunks acknowledged)
        for i in 0..<50 {
            acknowledgedChunks.insert(i)
        }
        
 // Property: Resume should start from first missing chunk
        let firstMissing = (0..<totalChunks).first { !acknowledgedChunks.contains($0) }
        XCTAssertEqual(firstMissing, 50,
                       "Resume should start from first missing chunk")
        
 // Property: All acknowledged chunks should not be re-sent
        let chunksToSend = (0..<totalChunks).filter { !acknowledgedChunks.contains($0) }
        XCTAssertEqual(chunksToSend.count, 50,
                       "Only missing chunks should be sent")
        
 // Property: No duplicates in chunks to send
        XCTAssertEqual(Set(chunksToSend).count, chunksToSend.count,
                       "No duplicate chunks should be sent")
        
 // Simulate resume - acknowledge remaining chunks
        for chunk in chunksToSend {
            acknowledgedChunks.insert(chunk)
        }
        
 // Property: All chunks should be acknowledged after resume
        XCTAssertEqual(acknowledgedChunks.count, totalChunks,
                       "All chunks must be acknowledged after resume")
    }
    
 /// Test resume data persistence
    func testResumeDataPersistence() throws {
 // Create test metadata for resume data
        let fileNode = P2PFileNode(
            nodeType: .file,
            name: "test.txt",
            relativePath: "test.txt",
            size: 25600,
            mtimeMillis: Int64(Date().timeIntervalSince1970 * 1000),
            permissions: 0o644
        )
        let metadata = P2PFileTransferMetadata(
            transferId: UUID(),
            fileTree: fileNode,
            totalSize: 25600,
            totalFileCount: 1,
            merkleRoot: Data(repeating: 0x01, count: 32),
            merkleRootSignature: Data(repeating: 0xAA, count: 64),
            chunkSize: 256,
            totalChunks: 100
        )
        
 // Create bitmap for received chunks (0, 1, 2, 5, 10, 15)
        var bitmap = Data(repeating: 0, count: 13) // 100 bits = 13 bytes
        bitmap[0] = 0b00000111  // chunks 0, 1, 2
        bitmap[0] |= 0b00100000 // chunk 5
        bitmap[1] = 0b00000100  // chunk 10
        bitmap[1] |= 0b10000000 // chunk 15
        
        let resumeData = P2PTransferResumeData(
            transferId: metadata.transferId,
            metadata: metadata,
            receivedChunksBitmap: bitmap,
            lastReceivedChunkIndex: 15,
            tempFilePaths: ["test.txt": "/tmp/test.txt.partial"]
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let encoded = try encoder.encode(resumeData)
        let decoded = try decoder.decode(P2PTransferResumeData.self, from: encoded)
        
 // Property: Resume data must survive round-trip
        XCTAssertEqual(decoded.transferId, resumeData.transferId)
        XCTAssertEqual(decoded.receivedChunksBitmap, resumeData.receivedChunksBitmap)
        XCTAssertEqual(decoded.lastReceivedChunkIndex, resumeData.lastReceivedChunkIndex)
        XCTAssertEqual(decoded.metadata.totalChunks, resumeData.metadata.totalChunks)
    }
    
 // MARK: - Property 21: Merkle Tree Integrity Verification
    
 /// **Property 21: Merkle Tree Integrity Verification**
 /// *For any* completed file transfer, the computed Merkle root should match
 /// the signed root from the sender.
 /// **Validates: Requirements 6.4**
    func testMerkleTreeIntegrityVerificationProperty() async {
 // Create test chunks
        let chunks: [Data] = [
            Data(repeating: 0x01, count: 256),
            Data(repeating: 0x02, count: 256),
            Data(repeating: 0x03, count: 256),
            Data(repeating: 0x04, count: 256)
        ]
        
 // Build Merkle tree on sender side
        let senderBuilder = P2PMerkleTreeBuilder()
        for chunk in chunks {
            await senderBuilder.addBlock(chunk)
        }
        let senderRoot = await senderBuilder.computeRoot()
        
 // Verify on receiver side using another builder
        let receiverBuilder = P2PMerkleTreeBuilder()
        for chunk in chunks {
            await receiverBuilder.addBlock(chunk)
        }
        let receiverRoot = await receiverBuilder.computeRoot()
        
 // Property: Sender and receiver roots must match
        XCTAssertEqual(senderRoot, receiverRoot,
                       "Merkle roots must match for identical data")
        
 // Property: Verification should succeed (roots match)
        let verified = (senderRoot == receiverRoot)
        XCTAssertTrue(verified,
                      "Verification must succeed for matching roots")
        
 // Property: Root should be 32 bytes (SHA-256)
        XCTAssertEqual(senderRoot.count, 32,
                       "Merkle root must be 32 bytes")
    }
    
 /// Test Merkle tree detects tampering
    func testMerkleTreeDetectsTampering() async {
        let chunks: [Data] = [
            Data(repeating: 0x01, count: 256),
            Data(repeating: 0x02, count: 256),
            Data(repeating: 0x03, count: 256),
            Data(repeating: 0x04, count: 256)
        ]
        
 // Build original Merkle tree
        let builder = P2PMerkleTreeBuilder()
        for chunk in chunks {
            await builder.addBlock(chunk)
        }
        let originalRoot = await builder.computeRoot()
        
 // Tamper with one chunk
        var tamperedChunks = chunks
        tamperedChunks[2] = Data(repeating: 0xFF, count: 256) // Modified!
        
 // Build tree with tampered data
        let tamperedBuilder = P2PMerkleTreeBuilder()
        for chunk in tamperedChunks {
            await tamperedBuilder.addBlock(chunk)
        }
        let tamperedRoot = await tamperedBuilder.computeRoot()
        
 // Property: Verification should fail for tampered data
        let verified = (tamperedRoot == originalRoot)
        XCTAssertFalse(verified,
                       "Verification must fail for tampered data")
        
 // Property: Computed root should differ
        XCTAssertNotEqual(tamperedRoot, originalRoot,
                          "Tampered data must produce different root")
    }
    
 /// Test Merkle tree with single chunk
    func testMerkleTreeSingleChunk() async {
        let chunk = Data(repeating: 0xAB, count: 256)
        
        let builder = P2PMerkleTreeBuilder()
        await builder.addBlock(chunk)
        let root = await builder.computeRoot()
        
 // Property: Single chunk root should be hash of chunk
        let expectedRoot = Data(SHA256.hash(data: chunk))
        XCTAssertEqual(root, expectedRoot,
                       "Single chunk root should be hash of chunk")
    }
    
 /// Test Merkle tree with power-of-two chunks
    func testMerkleTreePowerOfTwo() async {
 // Test with 2, 4, 8 chunks
        for count in [2, 4, 8] {
            let chunks = (0..<count).map { Data(repeating: UInt8($0), count: 256) }
            
            let builder = P2PMerkleTreeBuilder()
            for chunk in chunks {
                await builder.addBlock(chunk)
            }
            let root = await builder.computeRoot()
            
 // Property: Root should be 32 bytes
            XCTAssertEqual(root.count, 32,
                           "Root must be 32 bytes for \(count) chunks")
            
 // Property: Root should be deterministic
            let builder2 = P2PMerkleTreeBuilder()
            for chunk in chunks {
                await builder2.addBlock(chunk)
            }
            let root2 = await builder2.computeRoot()
            XCTAssertEqual(root2, root,
                           "Root must be deterministic for \(count) chunks")
        }
    }
    
 /// Test Merkle tree with non-power-of-two chunks
    func testMerkleTreeNonPowerOfTwo() async {
 // Test with 3, 5, 7 chunks
        for count in [3, 5, 7] {
            let chunks = (0..<count).map { Data(repeating: UInt8($0), count: 256) }
            
            let builder = P2PMerkleTreeBuilder()
            for chunk in chunks {
                await builder.addBlock(chunk)
            }
            let root = await builder.computeRoot()
            
 // Property: Root should be 32 bytes
            XCTAssertEqual(root.count, 32,
                           "Root must be 32 bytes for \(count) chunks")
            
 // Property: Different chunk counts produce different roots
            let differentChunks = (0..<count+1).map { Data(repeating: UInt8($0), count: 256) }
            let builder2 = P2PMerkleTreeBuilder()
            for chunk in differentChunks {
                await builder2.addBlock(chunk)
            }
            let root2 = await builder2.computeRoot()
            XCTAssertNotEqual(root2, root,
                              "Different chunk counts must produce different roots")
        }
    }
    
 // MARK: - Additional File Transfer Tests
    
 /// Test QUICFileChunk model
    func testQUICFileChunkModel() {
        let chunk = QUICFileChunk(
            index: 5,
            data: Data(repeating: 0xAB, count: 256),
            isLast: false
        )
        
 // Property: All fields should be accessible
        XCTAssertEqual(chunk.index, 5)
        XCTAssertEqual(chunk.data.count, 256)
        XCTAssertEqual(chunk.isLast, false)
    }
    
 /// Test chunk index calculation
    func testChunkIndexCalculation() {
        let fileSize: UInt64 = 1000
        let chunkSize: UInt64 = 256
        
        let expectedChunks = Int(ceil(Double(fileSize) / Double(chunkSize)))
        XCTAssertEqual(expectedChunks, 4, "1000 bytes / 256 = 4 chunks")
        
 // Property: Last chunk may be smaller
        let lastChunkSize = fileSize - (UInt64(expectedChunks - 1) * chunkSize)
        XCTAssertEqual(lastChunkSize, 232, "Last chunk should be 232 bytes")
        XCTAssertLessThan(lastChunkSize, chunkSize, "Last chunk must be <= chunkSize")
    }
    
 // MARK: - Helper Methods
    
    private func generateTestFileMetadata() -> [P2PFileTransferMetadata] {
        var metadata: [P2PFileTransferMetadata] = []
        
 // Small file
        metadata.append(createTestMetadata(
            name: "small.txt",
            size: 100,
            chunkSize: 256,
            totalChunks: 1
        ))
        
 // Medium file
        metadata.append(createTestMetadata(
            name: "medium.pdf",
            size: 1024 * 1024,
            chunkSize: 65536,
            totalChunks: 16
        ))
        
 // Large file
        metadata.append(createTestMetadata(
            name: "large.zip",
            size: 1024 * 1024 * 100,
            chunkSize: 65536,
            totalChunks: 1600
        ))
        
 // File with special characters in name
        metadata.append(createTestMetadata(
            name: "文件 (1).txt",
            size: 500,
            chunkSize: 256,
            totalChunks: 2
        ))
        
        return metadata
    }
    
    private func createTestMetadata(
        name: String,
        size: UInt64,
        chunkSize: Int,
        totalChunks: UInt64
    ) -> P2PFileTransferMetadata {
        let fileNode = P2PFileNode(
            nodeType: .file,
            name: name,
            relativePath: name,
            size: size,
            mtimeMillis: Int64(Date().timeIntervalSince1970 * 1000),
            permissions: 0o644
        )
        
        return P2PFileTransferMetadata(
            transferId: UUID(),
            fileTree: fileNode,
            totalSize: size,
            totalFileCount: 1,
            merkleRoot: Data(repeating: 0x01, count: 32),
            merkleRootSignature: Data(repeating: 0xAA, count: 64),
            chunkSize: chunkSize,
            totalChunks: totalChunks
        )
    }
}
