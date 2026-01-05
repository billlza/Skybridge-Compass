import Foundation
import SwiftUI
import OSLog
import CryptoKit

/// 设备信任记录 - 包含设备ID和信任时间
public struct TrustedDeviceRecord: Codable, Sendable {
    public let deviceId: String
    public let trustedDate: Date
    public let deviceName: String?
    
    public init(deviceId: String, trustedDate: Date = Date(), deviceName: String? = nil) {
        self.deviceId = deviceId
        self.trustedDate = trustedDate
        self.deviceName = deviceName
    }
}

/// 设备安全管理器 - 基于Apple 2025最佳实践
@MainActor
public class DeviceSecurityManager: BaseManager {
    
 // MARK: - 单例
    public static let shared = DeviceSecurityManager()
    
 // MARK: - 发布的属性
    @Published public var securityLevel: SecurityLevel = .medium
    @Published public var trustedDevices: [String] = []
    @Published public var securityStatus: String = "正常"
    
 // MARK: - 私有属性
    private let keychain = DeviceKeychainManager()
 /// 设备信任记录表（包含信任日期）
    private var trustedDeviceRecords: [String: TrustedDeviceRecord] = [:]
    private let trustRecordsKey = "SkyBridge.TrustedDeviceRecords"
    
 // MARK: - 初始化
    private init() {
        super.init(category: "DeviceSecurityManager")
    }
    
 // MARK: - BaseManager重写方法
    
 /// 执行设备安全管理器的初始化逻辑
    public override func performInitialization() async {
        await super.performInitialization()
        loadTrustedDevices()
        logger.info("✅ 设备安全管理器初始化完成")
    }
    
 // MARK: - 公共方法
    
 /// 添加受信任设备
    public func addTrustedDevice(_ device: DiscoveredDevice) {
        let deviceId = device.id.uuidString
        
        if !trustedDevices.contains(deviceId) {
            trustedDevices.append(deviceId)
 // 同时记录信任日期
            let record = TrustedDeviceRecord(deviceId: deviceId, trustedDate: Date(), deviceName: device.name)
            trustedDeviceRecords[deviceId] = record
            saveTrustedDevices()
            saveTrustRecords()
            logger.info("设备已添加到受信任列表: \(device.name)")
        }
    }
    
 /// 通过设备ID添加受信任设备（用于P2PDevice）
    public func addTrustedDeviceById(_ deviceId: String, name: String? = nil) {
        if !trustedDevices.contains(deviceId) {
            trustedDevices.append(deviceId)
            let record = TrustedDeviceRecord(deviceId: deviceId, trustedDate: Date(), deviceName: name)
            trustedDeviceRecords[deviceId] = record
            saveTrustedDevices()
            saveTrustRecords()
            logger.info("设备已添加到受信任列表: \(deviceId)")
        }
    }
    
 /// 移除受信任设备
    public func removeTrustedDevice(_ deviceId: String) {
        trustedDevices.removeAll { $0 == deviceId }
        trustedDeviceRecords.removeValue(forKey: deviceId)
        saveTrustedDevices()
        saveTrustRecords()
        logger.info("设备已从受信任列表移除: \(deviceId)")
    }
    
 /// 检查设备是否受信任
    public func isDeviceTrusted(_ device: DiscoveredDevice) -> Bool {
        return trustedDevices.contains(device.id.uuidString)
    }
    
 /// 获取设备的信任日期
 /// - Parameter deviceId: 设备ID
 /// - Returns: 信任日期，如果设备不在信任列表中返回nil
    public func getTrustedDate(for deviceId: String) -> Date? {
        return trustedDeviceRecords[deviceId]?.trustedDate
    }
    
 /// 获取设备的信任记录
    public func getTrustRecord(for deviceId: String) -> TrustedDeviceRecord? {
        return trustedDeviceRecords[deviceId]
    }
    
 /// 生成设备证书
    public func generateDeviceCertificate(for device: DiscoveredDevice) async throws -> DeviceCertificate {
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
 // 生成证书
                let certificate = DeviceCertificate(
                    deviceId: device.id.uuidString,
                    publicKey: Data(), // 这里应该是实际的公钥数据
                    issueDate: Date(),
                    expiryDate: Date().addingTimeInterval(365 * 24 * 60 * 60), // 1年有效期
                    securityLevel: .high
                )
                
 // 存储到钥匙串
                do {
                    let privateKey = P256.Signing.PrivateKey()
                    try self.keychain.savePrivateKey(privateKey, for: device.id.uuidString)
                    
 // 在主线程上更新UI状态
                    self.trustedDevices.append(device.id.uuidString)
                    
                    continuation.resume(returning: certificate)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
 /// 验证设备证书
    public func validateCertificate(_ certificate: DeviceCertificate) -> Bool {
 // 检查证书是否过期
        if certificate.expiryDate < Date() {
            logger.warning("证书已过期: \(certificate.deviceId)")
            return false
        }
        
 // 检查安全级别
        if certificate.securityLevel.rawValue < securityLevel.rawValue {
            logger.warning("证书安全级别不足: \(certificate.deviceId)")
            return false
        }
        
        logger.info("证书验证成功: \(certificate.deviceId)")
        return true
    }
    
 // MARK: - 私有方法
    
    private func loadTrustedDevices() {
 // 从UserDefaults加载受信任设备列表
        self.trustedDevices = UserDefaults.standard.stringArray(forKey: "TrustedDevices") ?? []
 // 加载信任记录
        loadTrustRecords()
        logger.info("已加载 \(self.trustedDevices.count) 个受信任设备")
    }
    
    private func saveTrustedDevices() {
        UserDefaults.standard.set(trustedDevices, forKey: "TrustedDevices")
        logger.info("受信任设备列表已保存")
    }
    
    private func loadTrustRecords() {
        guard let data = UserDefaults.standard.data(forKey: trustRecordsKey) else {
 // 兼容旧数据：为已存在的受信任设备创建记录（使用当前时间作为信任日期）
            for deviceId in trustedDevices where trustedDeviceRecords[deviceId] == nil {
                trustedDeviceRecords[deviceId] = TrustedDeviceRecord(deviceId: deviceId)
            }
            return
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([TrustedDeviceRecord].self, from: data)
            trustedDeviceRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.deviceId, $0) })
            
 // 确保所有受信任设备都有记录
            for deviceId in trustedDevices where trustedDeviceRecords[deviceId] == nil {
                trustedDeviceRecords[deviceId] = TrustedDeviceRecord(deviceId: deviceId)
            }
        } catch {
            logger.error("加载信任记录失败: \(error.localizedDescription)")
        }
    }
    
    private func saveTrustRecords() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let records = Array(trustedDeviceRecords.values)
            let data = try encoder.encode(records)
            UserDefaults.standard.set(data, forKey: trustRecordsKey)
        } catch {
            logger.error("保存信任记录失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - 安全级别

public enum SecurityLevel: String, CaseIterable, Codable, Sendable {
    case low = "低"
    case medium = "中"
    case high = "高"
    case critical = "关键"
    
    public var displayName: String {
        return rawValue
    }
}

// MARK: - 设备证书

public struct DeviceCertificate: Codable, Sendable {
    public let deviceId: String
    public let publicKey: Data
    public let issueDate: Date
    public let expiryDate: Date
    public let securityLevel: SecurityLevel
    
    public init(deviceId: String, publicKey: Data, issueDate: Date, expiryDate: Date, securityLevel: SecurityLevel) {
        self.deviceId = deviceId
        self.publicKey = publicKey
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.securityLevel = securityLevel
    }
}

// MARK: - 设备钥匙串管理器

private class DeviceKeychainManager {
    
    func savePrivateKey(_ privateKey: P256.Signing.PrivateKey, for deviceId: String) throws {
        let keyData = privateKey.rawRepresentation
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "device_private_key_\(deviceId)",
            kSecValueData as String: keyData
        ]
        
 // 删除现有的密钥
        SecItemDelete(query as CFDictionary)
        
 // 添加新密钥
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecurityError.keychainError("无法保存私钥: \(status)")
        }
    }
    
    func loadPrivateKey(for deviceId: String) throws -> P256.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "device_private_key_\(deviceId)",
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let keyData = result as? Data else {
            throw SecurityError.keychainError("无法加载私钥: \(status)")
        }
        
        return try P256.Signing.PrivateKey(rawRepresentation: keyData)
    }
}

// MARK: - 安全错误

public enum SecurityError: Error, LocalizedError {
    case keychainError(String)
    case certificateInvalid
    case encryptionFailed
    
    public var errorDescription: String? {
        switch self {
        case .keychainError(let message):
            return "钥匙串错误: \(message)"
        case .certificateInvalid:
            return "证书无效"
        case .encryptionFailed:
            return "加密失败"
        }
    }
}