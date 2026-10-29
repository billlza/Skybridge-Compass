//
// ConnectionApprovalService.swift
// SkyBridgeCore
//
// 多因素连接审批服务
// 支持 macOS 14.0+
//

import Foundation
import LocalAuthentication
import CryptoKit
import OSLog

// MARK: - 连接审批服务

/// 多因素连接审批服务
@MainActor
public final class ConnectionApprovalService: ObservableObject {

    // MARK: - Singleton

    public static let shared = ConnectionApprovalService()

    // MARK: - Published Properties

    /// 审批策略
    @Published public var policy: ApprovalPolicy {
        didSet { savePolicy() }
    }

    /// 待处理的审批请求
    @Published public private(set) var pendingRequests: [ConnectionApprovalRequest] = []

    /// 受信任设备列表
    @Published public private(set) var trustedDevices: [ApprovalTrustedDevice] = []

    /// 生物识别是否可用
    @Published public private(set) var biometricAvailable: Bool = false

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "ConnectionApproval")
    private let laContext = LAContext()
    private var cleanupTask: Task<Void, Never>?

    // 回调
    public var onApprovalRequired: ((ConnectionApprovalRequest) -> Void)?
    public var onApprovalResponse: ((ApprovalResponse) async throws -> Void)?

    private static let policyStore = CodablePersistenceStore<ApprovalPolicy>(
        location: .protectedApplicationSupport(
            path: "ConnectionApproval/policy.json",
            legacyUserDefaultsKey: "com.skybridge.approval.policy"
        )
    )
    private static let trustedDevicesStore = CodablePersistenceStore<[ApprovalTrustedDevice]>(
        location: .protectedApplicationSupport(
            path: "ConnectionApproval/trusted-devices.json",
            legacyUserDefaultsKey: "com.skybridge.approval.trustedDevices"
        )
    )

    // MARK: - Initialization

    private init() {
        self.policy = Self.loadPolicy() ?? .default
        self.trustedDevices = Self.loadTrustedDevices()

        checkBiometricAvailability()

        // 定期清理过期请求
        cleanupTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.cleanupExpiredRequests()
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
            }
        }

        logger.info("🔐 连接审批服务已初始化")
    }

    // MARK: - Public Methods - Request Handling

    /// 创建审批请求
    public func createRequest(
        deviceID: String,
        deviceName: String,
        deviceType: DeviceType
    ) async throws -> ConnectionApprovalRequest {
        // 检查是否是受信任设备
        if policy.autoApproveTrustedDevices {
            if let trusted = trustedDevices.first(where: { $0.deviceID == deviceID }) {
                if trusted.trustLevel == .elevated {
                    // 高级信任设备自动批准
                    logger.info("🔐 高级信任设备自动批准: \(deviceName)")
                    let request = ConnectionApprovalRequest(
                        requestingDeviceID: deviceID,
                        requestingDeviceName: deviceName,
                        requestingDeviceType: deviceType,
                        verificationCode: generateVerificationCode(),
                        challengeData: generateChallenge()
                    )
                    var approved = request
                    approved.status = .approved
                    return approved
                }
            }
        }

        // 检查待处理请求数量限制
        guard pendingRequests.count < policy.maxPendingRequests else {
            throw ConnectionApprovalError.tooManyPendingRequests
        }

        // 创建新请求
        let request = ConnectionApprovalRequest(
            requestingDeviceID: deviceID,
            requestingDeviceName: deviceName,
            requestingDeviceType: deviceType,
            verificationCode: generateVerificationCode(),
            challengeData: generateChallenge(),
            ttl: policy.requestTimeout
        )

        pendingRequests.append(request)

        // 通知 UI
        onApprovalRequired?(request)

        logger.info("🔐 创建审批请求: \(request.id) 来自 \(deviceName)")

        return request
    }

    /// 批准请求
    public func approveRequest(
        _ requestID: UUID,
        verificationCode: String? = nil,
        useBiometric: Bool = false
    ) async throws -> ApprovalResponse {
        guard let index = pendingRequests.firstIndex(where: { $0.id == requestID }) else {
            throw ConnectionApprovalError.requestNotFound
        }

        var request = pendingRequests[index]

        guard request.status == .pending else {
            throw ConnectionApprovalError.alreadyProcessed
        }

        guard !request.isExpired else {
            request.status = .expired
            pendingRequests[index] = request
            throw ConnectionApprovalError.requestExpired
        }

        var factorsUsed: [VerificationFactor] = []

        // 验证码验证
        if let code = verificationCode {
            guard code == request.verificationCode else {
                throw ConnectionApprovalError.verificationFailed
            }
            factorsUsed.append(.verificationCode)
        }

        // 生物识别验证
        if useBiometric && policy.enabledFactors.contains(.biometric) {
            let biometricSuccess = try await performBiometricAuth()
            guard biometricSuccess else {
                throw ConnectionApprovalError.biometricFailed
            }
            factorsUsed.append(.biometric)
        }

        // 检查是否满足必需因素数量
        guard factorsUsed.count >= policy.requiredFactorCount else {
            throw ConnectionApprovalError.verificationFailed
        }

        // 更新状态
        request.status = .approved
        pendingRequests[index] = request

        // 创建响应
        let response = ApprovalResponse(
            requestID: requestID,
            approved: true,
            respondingDeviceID: getLocalDeviceID(),
            verificationFactorsUsed: factorsUsed,
            signature: try signResponse(requestID: requestID, approved: true)
        )

        // 发送响应
        try await onApprovalResponse?(response)

        // 移除已处理的请求
        pendingRequests.remove(at: index)

        logger.info("🔐 请求已批准: \(requestID)")

        return response
    }

    /// 拒绝请求
    public func rejectRequest(_ requestID: UUID) async throws -> ApprovalResponse {
        guard let index = pendingRequests.firstIndex(where: { $0.id == requestID }) else {
            throw ConnectionApprovalError.requestNotFound
        }

        var request = pendingRequests[index]

        guard request.status == .pending else {
            throw ConnectionApprovalError.alreadyProcessed
        }

        request.status = .rejected
        pendingRequests[index] = request

        let response = ApprovalResponse(
            requestID: requestID,
            approved: false,
            respondingDeviceID: getLocalDeviceID(),
            verificationFactorsUsed: [],
            signature: try signResponse(requestID: requestID, approved: false)
        )

        try await onApprovalResponse?(response)

        pendingRequests.remove(at: index)

        logger.info("🔐 请求已拒绝: \(requestID)")

        return response
    }

    // MARK: - Public Methods - Trusted Devices

    /// 添加受信任设备
    public func addTrustedDevice(
        deviceID: String,
        deviceName: String,
        deviceType: DeviceType,
        trustLevel: ApprovalTrustLevel = .standard
    ) {
        // 检查是否已存在
        if let index = trustedDevices.firstIndex(where: { $0.deviceID == deviceID }) {
            trustedDevices.remove(at: index)
        }

        let device = ApprovalTrustedDevice(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: deviceType,
            trustLevel: trustLevel
        )

        trustedDevices.append(device)
        saveTrustedDevices()

        logger.info("🔐 添加受信任设备: \(deviceName)")
    }

    /// 移除受信任设备
    public func removeTrustedDevice(_ deviceID: String) {
        trustedDevices.removeAll { $0.deviceID == deviceID }
        saveTrustedDevices()

        logger.info("🔐 移除受信任设备: \(deviceID)")
    }

    /// 更新信任级别
    public func updateTrustLevel(_ deviceID: String, level: ApprovalTrustLevel) {
        guard let index = trustedDevices.firstIndex(where: { $0.deviceID == deviceID }) else {
            return
        }

        let old = trustedDevices[index]
        let updated = ApprovalTrustedDevice(
            deviceID: old.deviceID,
            deviceName: old.deviceName,
            deviceType: old.deviceType,
            trustLevel: level
        )

        trustedDevices[index] = updated
        saveTrustedDevices()
    }

    /// 检查设备是否受信任
    public func isDeviceTrusted(_ deviceID: String) -> Bool {
        trustedDevices.contains { $0.deviceID == deviceID }
    }

    // MARK: - Private Methods

    private func generateVerificationCode() -> String {
        // 生成6位数字验证码
        String(format: "%06d", Int.random(in: 0...999999))
    }

    private func generateChallenge() -> Data {
        // 生成随机挑战数据
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private func checkBiometricAvailability() {
        var error: NSError?
        biometricAvailable = laContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private func performBiometricAuth() async throws -> Bool {
        guard biometricAvailable else {
            return false
        }

        return try await withCheckedThrowingContinuation { continuation in
            laContext.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "验证身份以批准连接请求"
            ) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private func signResponse(requestID: UUID, approved: Bool) throws -> Data {
        // 使用 SHA256 签名响应
        let dataToSign = "\(requestID.uuidString):\(approved):\(Date().timeIntervalSince1970)"
        let hash = SHA256.hash(data: dataToSign.data(using: .utf8)!)
        return Data(hash)
    }

    private func cleanupExpiredRequests() async {
        var cleaned = false

        for i in pendingRequests.indices.reversed() {
            if pendingRequests[i].isExpired {
                pendingRequests[i].status = .expired
                pendingRequests.remove(at: i)
                cleaned = true
            }
        }

        if cleaned {
            logger.debug("🔐 已清理过期的审批请求")
        }
    }

    private func getLocalDeviceID() -> String {
        if let deviceID = UserDefaults.standard.string(forKey: "com.skybridge.deviceID") {
            return deviceID
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: "com.skybridge.deviceID")
        return newID
    }

    // MARK: - Persistence

    private func savePolicy() {
        try? Self.policyStore.save(policy)
    }

    private static func loadPolicy() -> ApprovalPolicy? {
        Self.policyStore.load()
    }

    private func saveTrustedDevices() {
        try? Self.trustedDevicesStore.save(trustedDevices)
    }

    private static func loadTrustedDevices() -> [ApprovalTrustedDevice] {
        Self.trustedDevicesStore.load() ?? []
    }
}
