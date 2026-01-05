import Foundation
@preconcurrency import Crypto

/// SSH 私钥导入工具
/// 中文说明：支持导入 OpenSSH Ed25519（未加密）与 PKCS#8 Ed25519 私钥。
/// 解析完成后返回 Crypto(Curve25519.Signing) 私钥对象，便于与 NIOSSH 集成。
public enum SSHKeyImporter {
 // MARK: - 错误类型
    public enum ImportError: Error, LocalizedError {
        case unsupportedFormat
        case encryptedKeyUnsupported
        case invalidPEM
        case invalidDER
        case invalidOpenSSH
        case algorithmNotSupported(String)
        case keyDataInvalid

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "不支持的私钥格式（仅支持 OpenSSH/PKCS#8 Ed25519）"
            case .encryptedKeyUnsupported: return "暂不支持加密的私钥，请先解密或使用未加密私钥"
            case .invalidPEM: return "PEM 内容无效或缺少 BEGIN/END 标记"
            case .invalidDER: return "DER 结构解析失败"
            case .invalidOpenSSH: return "OpenSSH 私钥结构无效"
            case .algorithmNotSupported(let alg): return "不支持的算法：\(alg)，仅支持 Ed25519"
            case .keyDataInvalid: return "私钥数据长度或内容无效"
            }
        }
    }

 // MARK: - 对外入口
 /// 从 PEM 文本导入 Ed25519 私钥（支持：OpenSSH 未加密 / PKCS#8）
    public static func importEd25519PrivateKey(fromPEM pem: String) throws -> Curve25519.Signing.PrivateKey {
        let normalized = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try importOpenSSHEd25519PrivateKey(pem: normalized)
        }
        if normalized.contains("BEGIN PRIVATE KEY") {
            return try importPKCS8Ed25519PrivateKey(pem: normalized)
        }
        throw ImportError.unsupportedFormat
    }

 // MARK: - OpenSSH（未加密）解析
 /// 解析 OpenSSH 私钥（ssh-ed25519，ciphername=none）
    private static func importOpenSSHEd25519PrivateKey(pem: String) throws -> Curve25519.Signing.PrivateKey {
 // 去除头尾标记并进行 Base64 解码
        guard let base64Body = extractPEMBody(pem: pem, begin: "BEGIN OPENSSH PRIVATE KEY", end: "END OPENSSH PRIVATE KEY"),
              let blob = Data(base64Encoded: base64Body) else {
            throw ImportError.invalidPEM
        }

        var r = ByteReader(blob)
 // 魔术头："openssh-key-v1\0"
        let magic = try r.readBytes(count: 15)
        guard String(data: magic, encoding: .utf8) == "openssh-key-v1\u{0000}" else {
            throw ImportError.invalidOpenSSH
        }
 // ciphername/kdfname/kdfoptions 均为 string（uint32长度 + 数据）
        let cipher = try r.readSSHString()
        let kdf = try r.readSSHString()
        _ = try r.readSSHString() // kdfoptions
        if cipher != "none" || kdf != "none" {
            throw ImportError.encryptedKeyUnsupported
        }
 // key 数量
        let keyCount = try r.readUInt32()
        guard keyCount == 1 else { throw ImportError.invalidOpenSSH }
 // 跳过公钥 blob（string）
        _ = try r.readSSHStringData()
 // 读取私钥块（string）
        let privBlock = try r.readSSHStringData()

        var pr = ByteReader(privBlock)
 // 两个校验整数（uint32），应相等
        let c1 = try pr.readUInt32()
        let c2 = try pr.readUInt32()
        guard c1 == c2 else { throw ImportError.invalidOpenSSH }

 // 键记录：type, pub, priv, comment
        let type = try pr.readSSHString()
        guard type == "ssh-ed25519" else { throw ImportError.algorithmNotSupported(type) }
        _ = try pr.readSSHStringData() // public key (32字节)
        let privateBlob = try pr.readSSHStringData() // 通常为 64 字节（seed32 + pub32）
        _ = try pr.readSSHString() // comment

 // 构造 CryptoKit/SwiftCrypto 私钥
 // Ed25519 私钥可用 32 字节 seed 或 64 字节原始表示进行初始化。
        let priv: Curve25519.Signing.PrivateKey
        if privateBlob.count == 64 {
            priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privateBlob)
        } else if privateBlob.count == 32 {
            priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privateBlob)
        } else {
            throw ImportError.keyDataInvalid
        }
        return priv
    }

 // MARK: - PKCS#8 Ed25519 解析（DER 简化实现）
 /// 解析 PKCS#8 的 Ed25519 私钥（BEGIN PRIVATE KEY）
 /// 注意：此实现仅针对 Ed25519 的常见 DER 结构，其他算法或变体将返回错误。
    private static func importPKCS8Ed25519PrivateKey(pem: String) throws -> Curve25519.Signing.PrivateKey {
        guard let base64Body = extractPEMBody(pem: pem, begin: "BEGIN PRIVATE KEY", end: "END PRIVATE KEY"),
              let der = Data(base64Encoded: base64Body) else {
            throw ImportError.invalidPEM
        }

        var r = ByteReader(der)
 // 读取 SEQUENCE 标签（0x30）
        guard try r.readByte() == 0x30 else { throw ImportError.invalidDER }
        let _ = try r.readDERLength() // 总长度，后续逐段解析

 // version: INTEGER 0
        guard try r.readByte() == 0x02, try r.readByte() == 0x01, try r.readByte() == 0x00 else {
            throw ImportError.invalidDER
        }

 // algorithm: SEQUENCE { OID 1.3.101.112 (Ed25519) [, params absent] }
        guard try r.readByte() == 0x30 else { throw ImportError.invalidDER }
        let _ = try r.readDERLength()
        guard try r.readByte() == 0x06 else { throw ImportError.invalidDER }
        let oidLen = try r.readDERLength()
        let oidData = try r.readBytes(count: oidLen)
 // Ed25519 OID = 1.3.101.112 -> DER 编码：06 03 2B 65 70（仅供验证，不逐字节比对序列长度）
 // 这里进行简单校验：检查内容包含 0x2B 0x65 0x70（1*40+3=43 -> 0x2B）
        guard oidData.contains(0x2B) && oidData.contains(0x65) && oidData.contains(0x70) else {
            throw ImportError.algorithmNotSupported("PKCS#8 OID 不为 Ed25519")
        }
 // 可选的参数字段通常不存在，如存在则跳过（不是常见情况）
        if r.peekByte() == 0x05 { // NULL
            _ = try r.readByte()
            _ = try r.readDERLength()
        }

 // privateKey: OCTET STRING（可能为 32 字节 seed，或包含前缀 0x04 0x20 + 32 字节）
        guard try r.readByte() == 0x04 else { throw ImportError.invalidDER }
        let pkLen = try r.readDERLength()
        var pk = try r.readBytes(count: pkLen)

 // 处理常见的内部格式：0x04 0x20 + 32字节
        if pk.count >= 34 && pk[0] == 0x04 && pk[1] == 0x20 {
            pk = pk.subdata(in: 2..<(2+32))
        }
        guard pk.count == 32 || pk.count == 64 else { throw ImportError.keyDataInvalid }

 // 构造 CryptoKit/SwiftCrypto 私钥
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: pk)
        return priv
    }

 // MARK: - 工具：PEM 提取
 /// 提取 PEM 主体（去除头尾标记与换行）
    private static func extractPEMBody(pem: String, begin: String, end: String) -> String? {
        guard let startRange = pem.range(of: "-----\(begin)-----"),
              let endRange = pem.range(of: "-----\(end)-----") else { return nil }
        let bodyRange = startRange.upperBound..<endRange.lowerBound
        let body = pem[bodyRange]
        return body
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 二进制读取器（DER/OpenSSH）
/// 简化的二进制读取器，专用于本文件的 DER/SSH 结构解析
fileprivate struct ByteReader {
    private let data: Data
    private var offset: Int = 0
    init(_ data: Data) { self.data = data }

 /// 读取一个字节
    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw SSHKeyImporter.ImportError.invalidDER }
        let b = data[offset]
        offset += 1
        return b
    }

 /// 读取若干字节
    mutating func readBytes(count: Int) throws -> Data {
        guard offset + count <= data.count else { throw SSHKeyImporter.ImportError.invalidDER }
        let sub = data.subdata(in: offset..<(offset+count))
        offset += count
        return sub
    }

 /// 读取 SSH 格式的字符串（uint32 长度 + 数据，作为 UTF-8 文本）
    mutating func readSSHString() throws -> String {
        let len = try Int(readUInt32())
        let buf = try readBytes(count: len)
        guard let s = String(data: buf, encoding: .utf8) else { throw SSHKeyImporter.ImportError.invalidOpenSSH }
        return s
    }

 /// 读取 SSH 字符串并返回原始数据
    mutating func readSSHStringData() throws -> Data {
        let len = try Int(readUInt32())
        return try readBytes(count: len)
    }

 /// 读取 uint32（大端）
    mutating func readUInt32() throws -> UInt32 {
        let d = try readBytes(count: 4)
        return d.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

 /// 读取 DER 长度（支持短形式和长形式）
    mutating func readDERLength() throws -> Int {
        let first = try readByte()
        if first & 0x80 == 0 { // 短形式
            return Int(first & 0x7F)
        }
        let count = Int(first & 0x7F)
        guard count > 0 && count <= 4 else { throw SSHKeyImporter.ImportError.invalidDER }
        var value: Int = 0
        for _ in 0..<count {
            let b = try readByte()
            value = (value << 8) | Int(b)
        }
        return value
    }

 /// 查看下一个字节但不移动偏移
    func peekByte() -> UInt8? {
        guard offset < data.count else { return nil }
        return data[offset]
    }
}