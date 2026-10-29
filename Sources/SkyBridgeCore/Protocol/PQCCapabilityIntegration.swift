import Foundation
import SkyBridgeProtocolCore

// MARK: - PQC Capability Integration

/// Legacy ML-DSA-65 compatibility/test capability projection.
///
/// 说明：
/// - `SkyBridgeProtocolCore` 只保留纯协议模型与协商规则。
/// - 本类型不用于产品 capability 或设置页，也不代表当前 committed
///   main-protocol identity；生产路径使用 exact algorithm/protection/raw-key snapshot。
@available(macOS 14.0, *)
public enum SBPQCCapabilityIntegration {

 /// 从 PQCProtocolAdapter 生成 PQC 算法列表
    public static func getPQCAlgorithms(from adapter: PQCProtocolAdapter) async -> [String] {
        let declaration = await adapter.generateCapabilityDeclaration()
        var algorithms: [String] = []

 // 添加支持的 KEM 变体
        algorithms.append(contentsOf: declaration.supportedKEMVariants)

 // 添加支持的签名变体
        algorithms.append(contentsOf: declaration.supportedSignatureVariants)

 // 如果支持 hybrid，添加 X-Wing
        if declaration.supportedSuites.contains("hybrid") {
            algorithms.append("X-Wing")
        }

        return algorithms
    }

 /// 从 PQCProtocolAdapter 生成加密模式列表
    public static func getEncryptionModes(from adapter: PQCProtocolAdapter) async -> [SBEncryptionMode] {
        let suites = await adapter.getSupportedSuites()
        return suites.map { suite -> SBEncryptionMode in
            switch suite {
            case .classic: return .classic
            case .pqc: return .pqc
            case .hybrid: return .hybrid
            }
        }
    }

 /// 生成包含 PQC 信息的能力协商请求
    public static func createNegotiationRequest(
        deviceId: String,
        capabilities: SBDeviceCapabilities,
        pqcAdapter: PQCProtocolAdapter
    ) async -> SBCapabilityNegotiationRequest {
        let encryptionModes = await getEncryptionModes(from: pqcAdapter)
        let pqcAlgorithms = await getPQCAlgorithms(from: pqcAdapter)

 // 检查是否支持 PQC 签名 (Requirements: 6.2)
        let pqcSignatureSupported = pqcAlgorithms.contains { algo in
            algo.contains("ML-DSA") || algo.contains("MLDSA")
        }

        return SBCapabilityNegotiationRequest(
            deviceId: deviceId,
            capabilities: capabilities,
            encryptionModes: encryptionModes,
            pqcAlgorithms: pqcAlgorithms.isEmpty ? nil : pqcAlgorithms,
            pqcSignatureSupported: pqcSignatureSupported
        )
    }

 /// 根据协商结果配置 PQCProtocolAdapter
    public static func applyNegotiationResult(
        response: SBCapabilityNegotiationResponse,
        to adapter: PQCProtocolAdapter
    ) async throws {
        guard response.success else {
            throw PQCProtocolError.noCommonSuite
        }

 // 根据协商的加密模式设置套件
        if let mode = SBEncryptionMode(rawValue: response.negotiatedEncryptionMode) {
            let suite: CrossPlatformPQCSuite
            switch mode {
            case .classic: suite = .classic
            case .pqc: suite = .pqc
            case .hybrid: suite = .hybrid
            }
            try await adapter.setSuite(suite)
        }
    }
}
