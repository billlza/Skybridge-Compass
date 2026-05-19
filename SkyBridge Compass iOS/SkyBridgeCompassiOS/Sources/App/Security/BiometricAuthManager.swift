import Foundation
import LocalAuthentication

/// 生物识别认证管理器
@MainActor
class BiometricAuthManager {
    static func checkAvailability() async {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            let biometryType = context.biometryType
            switch biometryType {
            case .faceID:
                SkyBridgeLogger.shared.info("✅ Face ID 可用")
            case .touchID:
                SkyBridgeLogger.shared.info("✅ Touch ID 可用")
            case .opticID:
                SkyBridgeLogger.shared.info("✅ Optic ID 可用")
            default:
                SkyBridgeLogger.shared.info("ℹ️ 无生物识别硬件")
            }
        } else {
            SkyBridgeLogger.shared.warning("⚠️ 生物识别不可用: \(error?.localizedDescription ?? "未知错误")")
        }
    }

    static func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            throw error
        }
    }
}
