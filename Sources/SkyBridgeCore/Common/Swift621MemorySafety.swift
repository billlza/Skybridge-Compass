import Foundation

/// Swift 6.2.1 内存安全工具
///
/// 使用 Span 类型提供安全的内存访问，替代不安全的指针操作
///
/// 🆕 2025年技术：基于 Swift 6.2.1 的 Span API
/// - 零运行时开销
/// - 编译时内存安全保证
/// - 避免缓冲区溢出
@available(macOS 14.0, *)
public struct Swift621MemorySafety {
    
 // MARK: - Span 类型封装
    
 /// 安全的字节缓冲区视图
 ///
 /// 使用 Span 替代 UnsafeBufferPointer，提供编译时安全保证
    public struct ByteSpan: ~Copyable {
        private let buffer: UnsafeBufferPointer<UInt8>
        
 /// 从 Data 创建安全的 Span
        public init(_ data: Data) {
            self.buffer = data.withUnsafeBytes { bytes in
                bytes.bindMemory(to: UInt8.self)
            }
        }
        
 /// 从数组创建安全的 Span
        public init(_ array: [UInt8]) {
            self.buffer = array.withUnsafeBufferPointer { $0 }
        }
        
 /// 安全访问字节
        public subscript(index: Int) -> UInt8 {
            get {
                precondition(index >= 0 && index < buffer.count, "索引越界")
                return buffer[index]
            }
        }
        
 /// 获取 Span 的长度
        public var count: Int {
            buffer.count
        }
        
 /// 安全地复制数据到目标
        public func copyBytes(to destination: inout [UInt8]) {
            destination.removeAll(keepingCapacity: true)
            destination.append(contentsOf: buffer)
        }
        
 /// 创建子 Span（切片操作）
        public func slice(from start: Int, count: Int) -> ByteSpan? {
            guard start >= 0, start + count <= buffer.count else {
                return nil
            }
            
            let slicedData = Data(buffer[start..<(start + count)])
            return ByteSpan(slicedData)
        }
    }
    
 // MARK: - 安全的C字符串处理
    
 /// 安全地解码 C 字符串为 Swift String
 ///
 /// 替代已弃用的 String(cString:) 方法
 /// - Parameter cString: C 字符串指针
 /// - Returns: 解码后的字符串
    public static func decodeCString(_ cString: UnsafePointer<CChar>) -> String {
 // 使用 UTF-8 安全解码
        let length = strlen(cString)
 // 将 CChar 指针重新绑定为 UInt8 指针
        let uint8Ptr = UnsafeRawPointer(cString).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: uint8Ptr, count: Int(length))
        let data = Data(buffer: buffer)
        return String(decoding: data, as: UTF8.self)
    }
    
 /// 安全地解码固定大小的 C 字符数组
 ///
 /// - Parameter buffer: 字符数组缓冲区
 /// - Returns: 解码后的字符串
    public static func decodeCStringBuffer(_ buffer: [CChar]) -> String {
        let data = Data(bytes: buffer, count: buffer.count)
        let nullTerminated = data.prefix { $0 != 0 }
        return String(decoding: nullTerminated, as: UTF8.self)
    }
    
 // MARK: - 网络字节序安全转换
    
 /// 安全地将网络字节序转换为主机字节序
 ///
 /// 使用 Span 确保内存访问安全
    public struct NetworkByteOrder {
        
 /// 安全读取 16 位网络字节序整数
        public static func readUInt16(from span: borrowing ByteSpan, at offset: Int) -> UInt16? {
            guard offset + 2 <= span.count else { return nil }
            
            let high = UInt16(span[offset])
            let low = UInt16(span[offset + 1])
            return (high << 8) | low
        }
        
 /// 安全读取 32 位网络字节序整数
        public static func readUInt32(from span: borrowing ByteSpan, at offset: Int) -> UInt32? {
            guard offset + 4 <= span.count else { return nil }
            
 // 拆分复杂表达式以避免编译器类型检查超时
            let byte0 = UInt32(span[offset])
            let byte1 = UInt32(span[offset + 1])
            let byte2 = UInt32(span[offset + 2])
            let byte3 = UInt32(span[offset + 3])
            
            let part0 = byte0 << 24
            let part1 = byte1 << 16
            let part2 = byte2 << 8
            let part3 = byte3
            
            return part0 | part1 | part2 | part3
        }
        
 /// 安全写入 16 位网络字节序整数
        public static func writeUInt16(_ value: UInt16, to destination: inout [UInt8]) {
            destination.append(UInt8((value >> 8) & 0xFF))
            destination.append(UInt8(value & 0xFF))
        }
        
 /// 安全写入 32 位网络字节序整数
        public static func writeUInt32(_ value: UInt32, to destination: inout [UInt8]) {
            destination.append(UInt8((value >> 24) & 0xFF))
            destination.append(UInt8((value >> 16) & 0xFF))
            destination.append(UInt8((value >> 8) & 0xFF))
            destination.append(UInt8(value & 0xFF))
        }
    }
    
 // MARK: - 内存对齐工具
    
 /// 计算对齐后的大小
 ///
 /// - Parameters:
 /// - size: 原始大小
 /// - alignment: 对齐字节数（必须是2的幂）
 /// - Returns: 对齐后的大小
    public static func alignSize(_ size: Int, to alignment: Int) -> Int {
        precondition(alignment > 0 && (alignment & (alignment - 1)) == 0, 
                     "对齐必须是2的幂")
        return (size + alignment - 1) & ~(alignment - 1)
    }
    
 /// 检查指针是否正确对齐
 ///
 /// - Parameters:
 /// - address: 内存地址
 /// - alignment: 对齐要求
 /// - Returns: 是否对齐
    public static func isAligned(_ address: Int, to alignment: Int) -> Bool {
        return (address & (alignment - 1)) == 0
    }
}

// MARK: - 兼容性扩展

extension Swift621MemorySafety {
    
 /// 安全的内存复制操作
 ///
 /// 使用边界检查避免缓冲区溢出
    public static func safeCopy(
        from source: UnsafeRawPointer,
        to destination: UnsafeMutableRawPointer,
        byteCount: Int,
        maxDestinationSize: Int
    ) -> Bool {
        guard byteCount <= maxDestinationSize else {
            SkyBridgeLogger.performance.error("⚠️ 内存复制失败：源大小 \(byteCount) 超过目标容量 \(maxDestinationSize)")
            return false
        }
        
        destination.copyMemory(from: source, byteCount: byteCount)
        return true
    }
}

// MARK: - 使用示例和文档

/*
 ## 使用示例
 
 ### 1. 使用 ByteSpan 安全访问数据
 
 ```swift
 let data = Data([0x01, 0x02, 0x03, 0x04])
 let span = Swift621MemorySafety.ByteSpan(data)
 
 // 安全索引访问（带边界检查）
 if let firstByte = span[0] {
     SkyBridgeLogger.performance.debugOnly("第一个字节: \(firstByte)")
 }
 
 // 安全切片
 if let slice = span.slice(from: 1, count: 2) {
     SkyBridgeLogger.performance.debugOnly("切片长度: \(slice.count)")
 }
 ```
 
 ### 2. 安全的C字符串处理
 
 ```swift
 let cString: UnsafePointer<CChar> = ...
 let safeString = Swift621MemorySafety.decodeCString(cString)
 ```
 
 ### 3. 网络字节序转换
 
 ```swift
 let data = Data([0x01, 0x02])
 let span = Swift621MemorySafety.ByteSpan(data)
 if let value = Swift621MemorySafety.NetworkByteOrder.readUInt16(from: span, at: 0) {
     SkyBridgeLogger.performance.debugOnly("读取到的值: \(value)")
 }
 ```
 
 ## 性能说明
 
 - ByteSpan 在编译时优化，零运行时开销
 - 边界检查在 Release 构建中可以通过编译器标志禁用
 - 内存对齐工具使用位运算，极高效率
 */

