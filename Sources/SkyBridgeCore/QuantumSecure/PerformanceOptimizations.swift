import Foundation
import CryptoKit
import MetalKit
import OSLog
import os.lock

/// 性能优化功能
/// 基于Apple 2025最佳实践
public class PerformanceOptimizations {
    
    private let logger = Logger(subsystem: "com.skybridge.quantum", category: "Performance")
    
 // MARK: - 1. 流式加密（大文件支持）
    
 /// 流式加密器
 /// 用于处理大文件，避免一次性加载到内存
    public class StreamingEncryptor {
        private let logger = Logger(subsystem: "com.skybridge.quantum", category: "StreamingEncrypt")
        private let key: SymmetricKey
        private let chunkSize: Int
        private var nonce: AES.GCM.Nonce
        
        public init(key: SymmetricKey, chunkSize: Int = 64 * 1024) { // 默认64KB块
            self.key = key
            self.chunkSize = chunkSize
            self.nonce = AES.GCM.Nonce() // 为每个块生成新nonce
        }
        
 /// 流式加密数据块
        public func encryptChunk(_ data: Data) throws -> EncryptedData {
 // 为每个块生成新的nonce（确保唯一性）
            let chunkNonce = AES.GCM.Nonce()
            
            let sealedBox = try AES.GCM.seal(data, using: key, nonce: chunkNonce)
            
            return EncryptedData(
                ciphertext: sealedBox.ciphertext,
                nonce: Data(chunkNonce),
                tag: Data(sealedBox.tag)
            )
        }
        
 /// 加密文件流
        public func encryptStream(
            from inputStream: InputStream,
            to outputStream: OutputStream
        ) async throws {
            logger.info("📦 开始流式加密")
            
            inputStream.open()
            outputStream.open()
            defer {
                inputStream.close()
                outputStream.close()
            }
            
            var totalBytes = 0
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { buffer.deallocate() }
            
            while inputStream.hasBytesAvailable {
                let bytesRead = inputStream.read(buffer, maxLength: chunkSize)
                guard bytesRead > 0 else { break }
                
                let chunk = Data(bytes: buffer, count: bytesRead)
                let encrypted = try encryptChunk(chunk)
                
 // 写入加密数据（格式：nonce(12) + tag(16) + ciphertext）
                let encryptedData = encrypted.combined
                let bytesWritten = encryptedData.withUnsafeBytes { bytes -> Int in
                    guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    return outputStream.write(base, maxLength: encryptedData.count)
                }
                
                guard bytesWritten == encryptedData.count else {
                    throw NSError(domain: "StreamingEncrypt", code: 1, userInfo: [NSLocalizedDescriptionKey: "写入失败"])
                }
                
                totalBytes += bytesRead
            }
            
            logger.info("✅ 流式加密完成，总大小: \(totalBytes) 字节")
        }
    }
    
 /// 流式解密器
    public class StreamingDecryptor {
        private let logger = Logger(subsystem: "com.skybridge.quantum", category: "StreamingDecrypt")
        private let key: SymmetricKey
        private let chunkSize: Int
        
        public init(key: SymmetricKey, chunkSize: Int = 64 * 1024) {
            self.key = key
            self.chunkSize = chunkSize
        }
        
 /// 解密文件流
        public func decryptStream(
            from inputStream: InputStream,
            to outputStream: OutputStream
        ) async throws {
            logger.info("📦 开始流式解密")
            
            inputStream.open()
            outputStream.open()
            defer {
                inputStream.close()
                outputStream.close()
            }
            
            var totalBytes = 0
 // 加密块的元数据大小：nonce(12) + tag(16) = 28字节
            let metadataSize = 28
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize + metadataSize)
            defer { buffer.deallocate() }
            
            while inputStream.hasBytesAvailable {
 // 先读取元数据
                var metadataBytes = 0
                while metadataBytes < metadataSize && inputStream.hasBytesAvailable {
                    let bytesRead = inputStream.read(buffer.advanced(by: metadataBytes), maxLength: metadataSize - metadataBytes)
                    guard bytesRead > 0 else { break }
                    metadataBytes += bytesRead
                }
                
                guard metadataBytes == metadataSize else { break }
                
 // 读取密文（尝试读取完整块）
                let ciphertextBytes = inputStream.read(buffer.advanced(by: metadataSize), maxLength: chunkSize)
                guard ciphertextBytes > 0 else { break }
                
 // 解析加密数据
                let encryptedData = Data(bytes: buffer, count: metadataSize + ciphertextBytes)
                let encrypted = try EncryptedData.from(combined: encryptedData)
                
 // 解密
                let sealedBox = try AES.GCM.SealedBox(
                    nonce: try AES.GCM.Nonce(data: encrypted.nonce),
                    ciphertext: encrypted.ciphertext,
                    tag: encrypted.tag
                )
                let decrypted = try AES.GCM.open(sealedBox, using: key)
                
 // 写入解密数据
                let bytesWritten = decrypted.withUnsafeBytes { bytes -> Int in
                    guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    return outputStream.write(base, maxLength: decrypted.count)
                }
                
                guard bytesWritten == decrypted.count else {
                    throw NSError(domain: "StreamingDecrypt", code: 1, userInfo: [NSLocalizedDescriptionKey: "写入失败"])
                }
                
                totalBytes += decrypted.count
            }
            
            logger.info("✅ 流式解密完成，总大小: \(totalBytes) 字节")
        }
    }
    
 // MARK: - 2. 并行加密处理
    
 /// 并行加密管理器
    public class ParallelEncryptionManager {
        private let logger = Logger(subsystem: "com.skybridge.quantum", category: "ParallelEncrypt")
        
 /// 并行加密多个数据块
        public func encryptInParallel(
            chunks: [Data],
            using keys: [SymmetricKey],
            maxConcurrency: Int = ProcessInfo.processInfo.processorCount
        ) async throws -> [EncryptedData] {
            logger.info("🚀 开始并行加密，块数: \(chunks.count)，并发数: \(maxConcurrency)")
            
            guard chunks.count == keys.count else {
                throw NSError(domain: "ParallelEncrypt", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据块和密钥数量不匹配"])
            }
            
 // 使用TaskGroup进行并行处理
            return try await withThrowingTaskGroup(of: (Int, EncryptedData).self) { group in
                var results = Array<EncryptedData?>(repeating: nil, count: chunks.count)
                
 // 启动所有任务
                for (index, (chunk, key)) in zip(chunks.indices, zip(chunks, keys)) {
                    group.addTask {
                        let nonce = AES.GCM.Nonce()
                        let sealedBox = try AES.GCM.seal(chunk, using: key, nonce: nonce)
                        
                        let encrypted = EncryptedData(
                            ciphertext: sealedBox.ciphertext,
                            nonce: Data(nonce),
                            tag: Data(sealedBox.tag)
                        )
                        
                        return (index, encrypted)
                    }
                }
                
 // 收集结果
                for try await (index, encrypted) in group {
                    results[index] = encrypted
                }
                
 // 确保所有结果都已完成
                guard let finalResults = results.compactMap({ $0 }) as [EncryptedData]?,
                      finalResults.count == chunks.count else {
                    throw NSError(domain: "ParallelEncrypt", code: 2, userInfo: [NSLocalizedDescriptionKey: "部分加密失败"])
                }
                
                logger.info("✅ 并行加密完成")
                return finalResults
            }
        }
        
 /// 并行解密多个数据块
        public func decryptInParallel(
            encryptedChunks: [EncryptedData],
            using keys: [SymmetricKey],
            maxConcurrency: Int = ProcessInfo.processInfo.processorCount
        ) async throws -> [Data] {
            logger.info("🚀 开始并行解密，块数: \(encryptedChunks.count)，并发数: \(maxConcurrency)")
            
            guard encryptedChunks.count == keys.count else {
                throw NSError(domain: "ParallelDecrypt", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据块和密钥数量不匹配"])
            }
            
            return try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var results = Array<Data?>(repeating: nil, count: encryptedChunks.count)
                
                for (index, (encrypted, key)) in zip(encryptedChunks.indices, zip(encryptedChunks, keys)) {
                    group.addTask {
                        let sealedBox = try AES.GCM.SealedBox(
                            nonce: try AES.GCM.Nonce(data: encrypted.nonce),
                            ciphertext: encrypted.ciphertext,
                            tag: encrypted.tag
                        )
                        
                        return (index, try AES.GCM.open(sealedBox, using: key))
                    }
                }
                
                for try await (index, decrypted) in group {
                    results[index] = decrypted
                }
                
                guard let finalResults = results.compactMap({ $0 }) as [Data]?,
                      finalResults.count == encryptedChunks.count else {
                    throw NSError(domain: "ParallelDecrypt", code: 2, userInfo: [NSLocalizedDescriptionKey: "部分解密失败"])
                }
                
                logger.info("✅ 并行解密完成")
                return finalResults
            }
        }
    }
    
 // MARK: - 3. Metal 加速（如果可用）
    
 /// Metal 加速加密（如果设备支持）
    public class MetalAcceleration {
        private let logger = Logger(subsystem: "com.skybridge.quantum", category: "MetalAcceleration")
        
 /// 检查Metal是否可用
        public static func isMetalAvailable() -> Bool {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return false
            }
            return device.supportsFamily(.common1) // 基本Metal支持
        }
        
 /// 使用Metal加速加密（实验性）
 /// 注意：Metal主要用于GPU计算，加密操作通常CPU更快
 /// 但对于大批量数据处理可能有用
        public func accelerateEncryptionIfAvailable(
            data: Data,
            key: SymmetricKey
        ) async throws -> EncryptedData {
            guard Self.isMetalAvailable() else {
                logger.info("⚠️ Metal不可用，使用CPU加密")
 // 回退到CPU加密
                let nonce = AES.GCM.Nonce()
                let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
                return EncryptedData(
                    ciphertext: sealedBox.ciphertext,
                    nonce: Data(nonce),
                    tag: Data(sealedBox.tag)
                )
            }
            
 // Metal可用于大规模并行数据处理，但CryptoKit的加密已经在硬件级别优化
 // 对于AES-GCM，CryptoKit使用AES-NI指令集（如果可用）
 // 因此Metal加速可能不会带来显著性能提升
            logger.info("ℹ️ Metal可用，但CryptoKit已使用硬件加速")
            
 // 仍然使用CryptoKit（它已经是最优的）
            let nonce = AES.GCM.Nonce()
            let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
            return EncryptedData(
                ciphertext: sealedBox.ciphertext,
                nonce: Data(nonce),
                tag: Data(sealedBox.tag)
            )
        }
        
 /// 使用Metal进行大批量哈希计算（如果适用）
        public func acceleratedHashingIfAvailable(data: Data) -> Data? {
            guard Self.isMetalAvailable() else {
                return nil
            }
            
 // CryptoKit已经使用硬件加速，Metal可能不会更快
 // 但对于自定义哈希函数可能有用
            logger.info("ℹ️ 使用CryptoKit硬件加速哈希（更优）")
            return Data(SHA256.hash(data: data))
        }
    }
}
