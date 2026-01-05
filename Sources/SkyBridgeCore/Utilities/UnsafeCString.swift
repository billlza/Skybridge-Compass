import Foundation

/// 提供安全、现代的 UTF8 C 字符串解码工具，统一替代 `String(cString:)`
/// 设计目标：
/// - 避免潜在的未终止或异常指针导致的崩溃
/// - 严格以 UTF8 解码，截断到首个空字符（\0）
/// - 在 Swift 6.2.1 严格并发环境下可用，不引入全局可变状态
@inlinable
public func decodeCString(_ ptr: UnsafePointer<CChar>) -> String {
 // 逐字节读取直到遇到首个空字符；避免依赖 `strlen`，提高安全性
    var bytes: [UInt8] = []
    var index = 0
    while true {
        let ch = ptr[index]
        if ch == 0 { break }
        bytes.append(UInt8(bitPattern: ch))
        index &+= 1
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// 可选指针版本，若指针为 `nil` 则返回 `nil`
@inlinable
public func decodeOptionalCString(_ ptr: UnsafePointer<CChar>?) -> String? {
    guard let p = ptr else { return nil }
    return decodeCString(p)
}

/// 针对以 `CChar` 数组形式提供的缓冲区，截断到首个空字符并以 UTF8 解码
@inlinable
public func decodeCCharBuffer(_ buffer: [CChar]) -> String {
    let truncated: [UInt8] = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: truncated, as: UTF8.self)
}