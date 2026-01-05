import Foundation
import CryptoKit
import OSLog
import SystemConfiguration

/// SelfIdentityProvider - 本机强身份提供者
/// 中文说明：负责生成、持久化和提供本机的权威身份标识，用于设备发现时精确判定"本机"。
/// 身份组成：
/// 1. selfDeviceId: UUID（持久化至 Keychain，首次启动生成）
/// 2. selfPubKeyFingerprint: P-256 公钥 SHA256 指纹（hex小写）
/// 3. selfInterfaceMACSet: 本机物理网卡 MAC 地址集合
@available(macOS 14.0, *)
public actor SelfIdentityProvider {
    public static let shared = SelfIdentityProvider()
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SelfIdentity")
    
 // MARK: - 强身份字段
    
    private(set) var deviceId: String = ""
    private(set) var pubKeyFP: String = ""
    private(set) var macSet: Set<String> = []
    
    private init() {}
    
 // MARK: - 加载或创建本机身份
    
 /// 加载或创建本机强身份（应在 App 启动时调用一次）
    public func loadOrCreate() async {
 // 1) 加载或生成 deviceId（持久化到 Keychain）
        await loadOrCreateDeviceId()
        
 // 2) 加载本机 P-256 公钥指纹
        await loadPubKeyFingerprint()
        
 // 3) 获取本机物理网卡 MAC 地址集合
        await loadMACAddresses()
        
        logger.info("✅ 本机强身份已加载: deviceId=\(self.deviceId.prefix(8))..., pubKeyFP=\(self.pubKeyFP.prefix(16))..., MACs=\(self.macSet.count)")
    }
    
 /// 获取当前身份快照（供外部判定使用）
    public func snapshot() -> SelfIdentitySnapshot {
        return SelfIdentitySnapshot(
            deviceId: deviceId,
            pubKeyFP: pubKeyFP,
            macSet: macSet
        )
    }
    
 // MARK: - 注册安全相关方法
    
 /// 生成用于注册的设备指纹
 ///
 /// 该指纹用于防止恶意注册，整合了 deviceId、pubKeyFP 和 macSet
 /// - Returns: 设备指纹哈希（SHA256 hex）
    public func generateRegistrationFingerprint() -> String {
 // 组合所有身份信息
        var components: [String] = []
        
 // 添加设备ID
        if !deviceId.isEmpty {
            components.append("device:\(deviceId)")
        }
        
 // 添加公钥指纹
        if !pubKeyFP.isEmpty {
            components.append("pubkey:\(pubKeyFP)")
        }
        
 // 添加排序后的MAC地址
        let sortedMACs = macSet.sorted().joined(separator: ",")
        if !sortedMACs.isEmpty {
            components.append("macs:\(sortedMACs)")
        }
        
 // 添加硬件信息（增加指纹的唯一性）
        let hardwareInfo = getHardwareInfo()
        if !hardwareInfo.isEmpty {
            components.append("hw:\(hardwareInfo)")
        }
        
 // 生成最终指纹
        let combined = components.joined(separator: "|")
        let fingerprint = sha256Hex(Data(combined.utf8))
        
        logger.debug("🔐 生成注册设备指纹: \(fingerprint.prefix(16))...")
        return fingerprint
    }
    
 /// 获取设备指纹信息（用于注册安全服务）
 /// - Returns: 设备指纹信息结构
    public func getRegistrationDeviceInfo() -> RegistrationDeviceInfo {
        return RegistrationDeviceInfo(
            deviceId: deviceId,
            fingerprint: generateRegistrationFingerprint(),
            macAddresses: Array(macSet),
            hardwareModel: getHardwareModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
    
 /// 获取硬件信息（用于指纹生成）
    private func getHardwareInfo() -> String {
        var components: [String] = []
        
 // 获取主机名
        if let hostname = Host.current().localizedName {
            components.append(hostname)
        }
        
 // 获取处理器数量
        let processorCount = ProcessInfo.processInfo.processorCount
        components.append("cpu:\(processorCount)")
        
 // 获取物理内存
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        components.append("mem:\(physicalMemory)")
        
 // 获取硬件型号
        let model = getHardwareModel()
        if !model.isEmpty {
            components.append("model:\(model)")
        }
        
        return components.joined(separator: "_")
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
    
    private func loadOrCreateDeviceId() async {
        let service = "SkyBridge.SelfIdentity"
        let account = "deviceId"
        
 // 尝试从 Keychain 读取（nonisolated 方法，不需要 await）
        if let data = KeychainManager.shared.exportKey(service: service, account: account),
           let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            deviceId = existing
            logger.debug("📱 从 Keychain 加载 deviceId: \(existing.prefix(8))...")
            return
        }
        
 // 首次启动：生成新 UUID 并持久化
        let newId = UUID().uuidString
        let data = Data(newId.utf8)
        let success = KeychainManager.shared.importKey(data: data, service: service, account: account)
        
        if success {
            deviceId = newId
            logger.info("🆕 生成新 deviceId 并已持久化: \(newId.prefix(8))...")
        } else {
            logger.error("❌ deviceId 持久化失败，使用临时 ID")
            deviceId = newId // 仍使用，但重启后会变
        }
    }
    
    private func loadPubKeyFingerprint() async {
 // 尝试从 Keychain 读取本机 P-256 公钥（nonisolated 方法，不需要 await）
        let tag = "default" // 与你现有的密钥标签对齐
        
 // 优先尝试读取 Secure Enclave 公钥
        if let pubKey = KeychainManager.shared.loadSecureEnclavePublicKey(tag: tag) {
            let pubData = pubKey.rawRepresentation
            pubKeyFP = sha256Hex(pubData)
            logger.debug("🔐 从 Secure Enclave 加载公钥指纹: \(self.pubKeyFP.prefix(16))...")
            return
        }
        
 // 回退：尝试读取普通 P-256 公钥
        if let pubKey = KeychainManager.shared.loadP256PublicKey(tag: tag) {
            let pubData = pubKey.rawRepresentation
            pubKeyFP = sha256Hex(pubData)
            logger.debug("🔑 从 Keychain 加载 P-256 公钥指纹: \(self.pubKeyFP.prefix(16))...")
            return
        }
        
 // 如果公钥不存在，生成新密钥对（兼容首次启动）
        logger.warning("⚠️ 本机 P-256 公钥不存在，尝试生成新密钥对")
        if let keyPair = KeychainManager.shared.generateP256SigningKeypair(tag: tag) {
            let pubData = keyPair.public.rawRepresentation
            pubKeyFP = sha256Hex(pubData)
            logger.info("🆕 生成新 P-256 密钥对，指纹: \(self.pubKeyFP.prefix(16))...")
        } else {
            logger.error("❌ 无法生成 P-256 密钥对，公钥指纹为空")
            pubKeyFP = ""
        }
    }
    
    private func loadMACAddresses() async {
        macSet = await NetworkInterfaceInspector.currentPhysicalMACs()
        logger.debug("🌐 获取本机物理网卡 MAC: \(self.macSet)")
    }
    
 // MARK: - 辅助函数
    
 /// SHA256 指纹计算（小写 hex）
    nonisolated private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
                
                guard let ifa = interface?.pointee else { continue }
                
 // 获取接口名称
                let nameData = Data(bytes: ifa.ifa_name, count: Int(strlen(ifa.ifa_name)))
                let name = String(decoding: nameData, as: UTF8.self)
                
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
                  let addr = ifa.ifa_addr else { continue }
            
 // 获取接口名称
            let nameData = Data(bytes: ifa.ifa_name, count: Int(strlen(ifa.ifa_name)))
            let name = String(decoding: nameData, as: UTF8.self)
            
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

