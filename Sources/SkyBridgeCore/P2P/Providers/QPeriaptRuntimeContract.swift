import Foundation
import SkyBridgeProtocolCore

#if canImport(CQPeriapt)
import CQPeriapt

enum QPeriaptRuntimeContract {
    static let expectedABIVersion: UInt32 = 2
    static let expectedRuntimeVersion = "0.1.0-alpha.2"
    static let expectedSuiteID = Array("ML-KEM-768+X25519".utf8)

    private static let validationResult: Result<Void, CryptoProviderError> = {
        do {
            try validateRuntime()
            return .success(())
        } catch let error as CryptoProviderError {
            return .failure(error)
        } catch {
            return .failure(.operationFailed("Q-Periapt runtime validation failed: \(error.localizedDescription)"))
        }
    }()

    static var isCompatible: Bool {
        if case .success = validationResult {
            return true
        }
        return false
    }

    static func requireCompatible() throws {
        try validationResult.get()
    }

    static func statusDescription(_ status: Int32) -> String {
        guard let statusPointer = q_periapt_status_name(status) else {
            return "status=\(status)"
        }
        return "\(String(cString: statusPointer)) (\(status))"
    }

    private static func validateRuntime() throws {
        let runtimeABI = q_periapt_abi_version()
        guard runtimeABI == expectedABIVersion else {
            throw CryptoProviderError.operationFailed(
                "Q-Periapt C ABI mismatch: header=\(expectedABIVersion), runtime=\(runtimeABI)"
            )
        }

        guard UInt32(Q_PERIAPT_ABI_VERSION) == expectedABIVersion,
              UInt8(Q_PERIAPT_PROFILE_CONTEXT_BOUND) == 2,
              UInt8(Q_PERIAPT_POLICY_DECISION_VERSION) == 1,
              UInt8(Q_PERIAPT_SUITE_MLKEM768_X25519) == 1,
              UInt8(Q_PERIAPT_KEY_FORMAT_EXPANDED) == 1,
              Int(Q_PERIAPT_POLICY_DECISION_LEN) == 40,
              Int(Q_PERIAPT_TRUSTED_POLICY_STATE_LEN) == 36,
              Int(Q_PERIAPT_MAX_SIGNED_POLICY_BYTES) == 65_536,
              Int(Q_PERIAPT_MAX_APPLICATION_CONTEXT_BYTES) == 65_536,
              Int(Q_PERIAPT_MLKEM768_SK_LEN) == 2_400,
              Int(Q_PERIAPT_MLKEM768_PK_LEN) == 1_184,
              Int(Q_PERIAPT_MLKEM768_CT_LEN) == 1_088,
              Int(Q_PERIAPT_X25519_LEN) == 32,
              Int(Q_PERIAPT_SECRET_LEN) == 32,
              Int32(Q_PERIAPT_OK) == 0,
              Int32(Q_PERIAPT_ERR_NULL) == -1,
              Int32(Q_PERIAPT_ERR_LENGTH) == -2,
              Int32(Q_PERIAPT_ERR_POLICY) == -3,
              Int32(Q_PERIAPT_ERR_PANIC) == -4,
              Int32(Q_PERIAPT_ERR_INTERNAL) == -5,
              Int32(Q_PERIAPT_ERR_INVALID_KEYSHARE) == -6,
              Int32(Q_PERIAPT_ERR_ALIASING) == -7,
              Int32(Q_PERIAPT_ERR_ENTROPY) == -8 else {
            throw CryptoProviderError.operationFailed(
                "Q-Periapt header changed the frozen SkyBridge ABI2 PolicyBound contract"
            )
        }

        let runtimeSuiteLength = Int(q_periapt_fixed_suite_id_len())
        guard runtimeSuiteLength == expectedSuiteID.count,
              let suitePointer = q_periapt_fixed_suite_id() else {
            throw CryptoProviderError.operationFailed(
                "Q-Periapt fixed suite metadata is missing or has an invalid length"
            )
        }
        let runtimeSuiteID = Array(
            UnsafeRawBufferPointer(
                start: UnsafeRawPointer(suitePointer),
                count: runtimeSuiteLength
            )
        )
        guard runtimeSuiteID == expectedSuiteID else {
            throw CryptoProviderError.operationFailed(
                "Q-Periapt fixed suite mismatch: expected ML-KEM-768+X25519"
            )
        }

        guard let versionPointer = q_periapt_version() else {
            throw CryptoProviderError.operationFailed("Q-Periapt runtime version metadata is missing")
        }
        let runtimeVersion = String(cString: versionPointer)
        guard runtimeVersion == expectedRuntimeVersion else {
            throw CryptoProviderError.operationFailed(
                "Q-Periapt runtime version mismatch: expected \(expectedRuntimeVersion), got \(runtimeVersion)"
            )
        }
    }
}
#endif
