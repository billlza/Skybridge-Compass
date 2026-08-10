import Foundation
import CryptoKit
import OSLog
import SystemConfiguration

/// SelfIdentityProvider - 本机强身份提供者
/// 中文说明：提供由 DeviceIdentity authority 统一绑定的本机强身份，用于设备发现时精确判定"本机"。
/// 身份组成：
/// 1. selfDeviceId: immutable identity authority 中的 device ID
/// 2. selfPubKeyFingerprint: 同一 authority 中 P-256 公钥的 SHA256 指纹（hex小写）
/// 3. selfInterfaceMACSet: 本机物理网卡 MAC 地址集合
@available(macOS 14.0, *)
public actor SelfIdentityProvider {
    public static let shared = SelfIdentityProvider()

    private typealias IdentityLoader = @Sendable (Bool) async throws -> DeviceIdentityKeyInfo?
    private typealias ReadOnlyIdentityLoader = @Sendable () async throws -> DeviceIdentityKeyInfo?
    private typealias DeviceIDMirror = @Sendable (String) -> Bool
    private typealias MACAddressLoader = @Sendable () async -> Set<String>
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SelfIdentity")
    
 // MARK: - 强身份字段
    
    private(set) var deviceId: String = ""
    private(set) var pubKeyFP: String = ""
    private(set) var macSet: Set<String> = []

    private let identityLoader: IdentityLoader
    private let readOnlyIdentityLoader: ReadOnlyIdentityLoader
    private let deviceIDMirror: DeviceIDMirror
    private let macAddressLoader: MACAddressLoader

    private init() {
        identityLoader = { allowCreate in
            let manager = DeviceIdentityKeyManager.shared
            if allowCreate {
                return try await manager.getOrCreateIdentityKey()
            }
            return try await manager.existingIdentityKeyInfoStrict()
        }
        readOnlyIdentityLoader = {
            try await DeviceIdentityKeyManager.shared
                .existingIdentityAuthoritySnapshotReadOnly()
        }
        deviceIDMirror = { deviceID in
            guard let data = deviceID.data(using: .utf8) else { return false }
            return KeychainManager.shared.importKey(
                data: data,
                service: DeviceIDStorage.service,
                account: DeviceIDStorage.account
            )
        }
        macAddressLoader = {
            await NetworkInterfaceInspector.currentPhysicalMACs()
        }
    }

    /// Deterministic persistence seam for strict identity/error-path tests.
    init(
        identityLoader: @escaping @Sendable (Bool) async throws -> DeviceIdentityKeyInfo?,
        readOnlyIdentityLoader: (@Sendable () async throws -> DeviceIdentityKeyInfo?)? = nil,
        deviceIDMirror: @escaping @Sendable (String) -> Bool = { _ in true },
        macAddressLoader: @escaping @Sendable () async -> Set<String> = { [] }
    ) {
        self.identityLoader = identityLoader
        self.readOnlyIdentityLoader = readOnlyIdentityLoader ?? {
            try await identityLoader(false)
        }
        self.deviceIDMirror = deviceIDMirror
        self.macAddressLoader = macAddressLoader
    }

    private enum DeviceIDStorage {
        static let service = "SkyBridge.SelfIdentity"
        static let account = "deviceId"
    }
    
 // MARK: - 加载或创建本机身份
    
    /// 加载或创建本机强身份（应在 App 启动时调用一次）。
    ///
    /// Device ID 与公钥指纹必须来自同一次 authority 解析；Keychain 损坏、
    /// 迁移冲突和缺少 entitlement 都直接传播给调用方。
    public func loadOrCreate() async throws {
        _ = try await loadAuthoritativeIdentity(allowCreate: true)
        await loadMACAddresses()
        
        logger.info("✅ 本机强身份已加载: deviceId=\(self.deviceId.prefix(8))..., pubKeyFP=\(self.pubKeyFP.prefix(16))..., MACs=\(self.macSet.count)")
    }
    
    /// Return the currently published presentation snapshot.
    ///
    /// This internal view may be empty before authority prewarm and is suitable only
    /// for non-authorizing discovery cleanup or diagnostics. Security, signaling,
    /// persistence and trust paths must use `snapshotEnsuringProtocolDeviceId` or
    /// `protocolIdentityDeviceId`, both of which fail closed.
    func presentationSnapshot() -> SelfIdentitySnapshot {
        SelfIdentitySnapshot(
            deviceId: deviceId,
            pubKeyFP: pubKeyFP,
            macSet: macSet
        )
    }

    /// Return the protocol identity deviceId without depending on startup prewarm.
    ///
    /// Some transport control paths run before the full self-identity actor has
    /// been warmed.  A blank deviceId is worse than an omitted optional field:
    /// peers can cache it as a successful bootstrap with no stable authority.
    public func protocolIdentityDeviceId(allowCreate: Bool) async throws -> String {
        try await loadAuthoritativeIdentity(allowCreate: allowCreate).deviceId
    }

    /// Reads and validates the existing authority without creating, migrating,
    /// mirroring, or publishing identity state. Unauthenticated inbound sockets
    /// must use this accessor instead of a mutating startup/presentation path.
    public func existingProtocolIdentityDeviceIdReadOnly() async throws -> String {
        guard let identity = try await readOnlyIdentityLoader() else {
            throw DeviceIdentityKeyError.keyNotFound
        }
        return try Self.validatedAuthoritativeIdentity(identity).deviceId
    }

    public func snapshotEnsuringProtocolDeviceId(
        allowCreate: Bool
    ) async throws -> SelfIdentitySnapshot {
        _ = try await loadAuthoritativeIdentity(allowCreate: allowCreate)
        return SelfIdentitySnapshot(
            deviceId: deviceId,
            pubKeyFP: pubKeyFP,
            macSet: macSet
        )
    }
    
 // MARK: - 注册安全相关方法
    
    /// Generate the registration-policy fingerprint from the canonical authority tuple.
    ///
    /// The input is deliberately limited to the immutable authority device ID and its
    /// matching P-256 public-key fingerprint. Host names, MAC addresses, model data and
    /// other mutable hardware presentation fields are not identity authority.
    public func generateRegistrationFingerprint(
        allowCreate: Bool
    ) async throws -> String {
        let identity = try await loadAuthoritativeIdentity(allowCreate: allowCreate)
        let fingerprint = Self.registrationFingerprint(
            deviceId: identity.deviceId,
            publicKeyFingerprint: identity.pubKeyFP
        )
        
        logger.debug("🔐 生成注册设备指纹: \(fingerprint.prefix(16))...")
        return fingerprint
    }

    /// Versioned and length-delimited encoding prevents tuple ambiguity and makes future
    /// migrations explicit instead of silently changing an account-policy identifier.
    nonisolated static func registrationFingerprint(
        deviceId: String,
        publicKeyFingerprint: String
    ) -> String {
        var material = Data("com.skybridge.registration-device-fingerprint.v1".utf8)
        appendRegistrationFingerprintField(deviceId, to: &material)
        appendRegistrationFingerprintField(publicKeyFingerprint, to: &material)
        let digest = SHA256.hash(data: material)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func appendRegistrationFingerprintField(
        _ value: String,
        to data: inout Data
    ) {
        let field = Data(value.utf8)
        var byteCount = UInt64(field.count).bigEndian
        withUnsafeBytes(of: &byteCount) { data.append(contentsOf: $0) }
        data.append(field)
    }
    
 /// 获取设备指纹信息（用于注册安全服务）
 /// - Returns: 设备指纹信息结构
    public func getRegistrationDeviceInfo(
        allowCreate: Bool
    ) async throws -> RegistrationDeviceInfo {
        let identity = try await loadAuthoritativeIdentity(allowCreate: allowCreate)
        return RegistrationDeviceInfo(
            deviceId: identity.deviceId,
            fingerprint: Self.registrationFingerprint(
                deviceId: identity.deviceId,
                publicKeyFingerprint: identity.pubKeyFP
            ),
            macAddresses: Array(macSet),
            hardwareModel: getHardwareModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
    
 /// 获取硬件型号（避免使用已废弃的 String(cString:)）
    private func getHardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        
        guard size > 0 else { return "" }
        
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        
 // 转为 UInt8 并截断到首个 `\\0`，再用 UTF8 解码，兼容 Swift 6.2.1
        let bytes: [UInt8] = model.map { UInt8(bitPattern: $0) }
        if let terminator = bytes.firstIndex(of: 0) {
            let slice = bytes.prefix(terminator)
            return String(decoding: slice, as: UTF8.self)
        } else {
            return String(decoding: bytes, as: UTF8.self)
        }
    }
    
 // MARK: - 私有加载逻辑

    private func loadAuthoritativeIdentity(
        allowCreate: Bool
    ) async throws -> DeviceIdentityKeyInfo {
        guard let loadedIdentity = try await identityLoader(allowCreate) else {
            throw DeviceIdentityKeyError.keyNotFound
        }
        let identity = try Self.validatedAuthoritativeIdentity(loadedIdentity)

        // Publish both fields together only after the complete authority tuple
        // has passed validation. The historical store is write-only here and can
        // never become an identity source.
        deviceId = identity.deviceId
        pubKeyFP = identity.pubKeyFP
        if !DeviceIdentityKeyManager.requiresExistingOnlyIdentityRuntime,
           !deviceIDMirror(identity.deviceId) {
            logger.warning(
                "⚠️ Failed to update the non-authoritative device ID mirror"
            )
        }
        return identity
    }

    nonisolated private static func validatedAuthoritativeIdentity(
        _ identity: DeviceIdentityKeyInfo
    ) throws -> DeviceIdentityKeyInfo {
        let normalizedDeviceID = identity.deviceId.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalizedDeviceID == identity.deviceId,
              !normalizedDeviceID.isEmpty,
              identity.keyType == .p256Signing else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Self identity is not a valid P-256 device authority"
            )
        }
        do {
            _ = try P256.Signing.PublicKey(
                x963Representation: identity.publicKey
            )
        } catch {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Self identity authority contains an invalid P-256 public key"
            )
        }
        guard identity.pubKeyFP == DeviceIdentityAuthorityRecord.fingerprint(
            for: identity.publicKey
        ) else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Self identity fingerprint does not match its authority public key"
            )
        }
        return identity
    }
    
    private func loadMACAddresses() async {
        macSet = await macAddressLoader()
        logger.debug("🌐 获取本机物理网卡 MAC: \(self.macSet)")
    }
    
}

// MARK: - 本机身份快照（Sendable，供跨 actor 传递）

/// 本机强身份快照
public struct SelfIdentitySnapshot: Sendable, Equatable {
    public let deviceId: String
    public let pubKeyFP: String
    public let macSet: Set<String>
    
    public init(deviceId: String, pubKeyFP: String, macSet: Set<String>) {
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
        self.macSet = macSet
    }
}

// MARK: - 注册设备信息（用于注册安全服务）

/// 注册设备信息
public struct RegistrationDeviceInfo: Sendable, Codable {
 /// 设备唯一ID
    public let deviceId: String
 /// 设备指纹哈希
    public let fingerprint: String
 /// MAC地址列表
    public let macAddresses: [String]
 /// 硬件型号
    public let hardwareModel: String
 /// 操作系统版本
    public let osVersion: String
    
    public init(deviceId: String, fingerprint: String, macAddresses: [String], hardwareModel: String, osVersion: String) {
        self.deviceId = deviceId
        self.fingerprint = fingerprint
        self.macAddresses = macAddresses
        self.hardwareModel = hardwareModel
        self.osVersion = osVersion
    }
}

// MARK: - 网络接口 MAC 地址获取工具

import Darwin

/// 网络接口检查器（获取本机物理网卡 MAC 地址）
struct NetworkInterfaceInspector {
 /// 获取本机所有物理网卡的 MAC 地址集合
    static func currentPhysicalMACs() async -> Set<String> {
        return await Task.detached(priority: .utility) {
            var macs = Set<String>()
            var ifaddrs: UnsafeMutablePointer<ifaddrs>?
            
            guard getifaddrs(&ifaddrs) == 0 else { return macs }
            defer { freeifaddrs(ifaddrs) }
            
            var interface = ifaddrs
            while interface != nil {
                defer { interface = interface?.pointee.ifa_next }
                
                guard let ifa = interface?.pointee,
                      let name = decodeOptionalCString(ifa.ifa_name) else { continue }
                
 // 只获取物理网卡（排除虚拟网卡、lo、utun 等）
                guard isPhysicalInterface(name) else { continue }
                
 // 获取 MAC 地址（通过 SIOCGIFHWADDR 或从 link layer 读取）
                if let mac = getMACAddress(for: name) {
                    macs.insert(mac)
                }
            }
            
            return macs
        }.value
    }
    
 /// 判断是否为物理网卡（排除虚拟网卡）
    private static func isPhysicalInterface(_ name: String) -> Bool {
 // 排除虚拟网卡、loopback、utun、awdl 等
        let virtualPrefixes = ["lo", "utun", "awdl", "bridge", "llw", "ap", "p2p", "stf"]
        for prefix in virtualPrefixes {
            if name.hasPrefix(prefix) { return false }
        }
        
 // 保留物理网卡：en0（Wi-Fi）、en1（以太网）等
        return name.hasPrefix("en") || name.hasPrefix("eth")
    }
    
 /// 获取指定接口的 MAC 地址
    private static func getMACAddress(for interfaceName: String) -> String? {
        var ifr = ifreq()
        let ifnameBytes = interfaceName.utf8CString
        guard ifnameBytes.count <= MemoryLayout.size(ofValue: ifr.ifr_name) else { return nil }
        
 // Swift 6.2.1: withUnsafeMutableBytes 返回 Void，不需要 _ =
        withUnsafeMutableBytes(of: &ifr.ifr_name) { ptr in
            ifnameBytes.withUnsafeBytes { src in
                ptr.copyBytes(from: src)
            }
        }
        
        let sockfd = socket(AF_INET, SOCK_DGRAM, 0)
        guard sockfd >= 0 else { return nil }
        defer { close(sockfd) }
        
 // macOS 使用 AF_LINK 从 if_data 获取 MAC
 // 更简单的方式：直接读取 IOKit（但这里用 BSD 兼容方式）
        
 // 由于 macOS 不支持 SIOCGIFHWADDR，改用 sysctl 或遍历 AF_LINK
 // 简化实现：返回 nil，依赖 AF_LINK 方法（见下方改进）
        
        return nil
    }
    
 /// 使用 BSD 接口直接获取 MAC 地址（简化实现）
 /// Swift 6.2.1 注释：SystemConfiguration API 在 Swift 中使用较复杂，
 /// 这里改用 BSD socket API 的 AF_LINK 方式获取，更可靠且跨平台。
    static func getMACAddressesViaAFLink() -> Set<String> {
        var macs = Set<String>()
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddrs) == 0 else { return macs }
        defer { freeifaddrs(ifaddrs) }
        
        var interface = ifaddrs
        while interface != nil {
            defer { interface = interface?.pointee.ifa_next }
            
            guard let ifa = interface?.pointee,
                  let name = decodeOptionalCString(ifa.ifa_name),
                  let addr = ifa.ifa_addr else { continue }
            
 // 只处理物理网卡
            guard isPhysicalInterface(name) else { continue }
            
 // 读取 AF_LINK 层的 MAC 地址
 // Swift 6.2.1: 在 withMemoryRebound 闭包内完成所有操作，避免指针悬垂
            if addr.pointee.sa_family == UInt8(AF_LINK) {
                let macAddress = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dlPtr -> String? in
                    let sockaddr_dl = dlPtr.pointee
                    
 // MAC 地址长度通常为 6 字节
                    guard sockaddr_dl.sdl_alen == 6 else { return nil }
                    
 // 在闭包内安全地访问 sdl_data
                    return withUnsafePointer(to: sockaddr_dl.sdl_data) { dataPtr in
                        let basePtr = UnsafeRawPointer(dataPtr)
                        let macPtr = basePtr.advanced(by: Int(sockaddr_dl.sdl_nlen))
                        let macBytes = macPtr.assumingMemoryBound(to: UInt8.self)
                        
 // 格式化为 "xx:xx:xx:xx:xx:xx" 小写
                        let macParts = (0..<6).map { String(format: "%02x", macBytes[$0]) }
                        return macParts.joined(separator: ":")
                    }
                }
                
                if let macAddress = macAddress, !macAddress.isEmpty, macAddress != "00:00:00:00:00:00" {
                    macs.insert(macAddress)
                }
            }
        }
        
        return macs
    }
    
 /// 归一化 MAC 地址格式
    private static func normalizeMACAddress(_ mac: String) -> String {
        let cleaned = mac.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        
        guard cleaned.count == 12 else { return "" }
        
        var result = ""
        for (index, char) in cleaned.enumerated() {
            result.append(char)
            if index % 2 == 1 && index < 11 {
                result.append(":")
            }
        }
        return result
    }
}
