import CQPeriapt
import Foundation

public enum QPeriaptRuntimeContractError: Error, LocalizedError, Sendable, Equatable {
    case abiMismatch(expected: UInt32, actual: UInt32)
    case frozenHeaderContractChanged
    case invalidSuiteMetadata
    case suiteMismatch
    case missingRuntimeVersion
    case runtimeVersionMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .abiMismatch(let expected, let actual):
            return "Q-Periapt C ABI mismatch: header=\(expected), runtime=\(actual)"
        case .frozenHeaderContractChanged:
            return "Q-Periapt header changed the frozen SkyBridge ABI2 PolicyBound contract"
        case .invalidSuiteMetadata:
            return "Q-Periapt fixed suite metadata is missing or has an invalid length"
        case .suiteMismatch:
            return "Q-Periapt fixed suite mismatch: expected ML-KEM-768+X25519"
        case .missingRuntimeVersion:
            return "Q-Periapt runtime version metadata is missing"
        case .runtimeVersionMismatch(let expected, let actual):
            return "Q-Periapt runtime version mismatch: expected \(expected), got \(actual)"
        }
    }
}

/// Frozen host-side contract for the published Q-Periapt ABI2 binary.
public enum QPeriaptRuntimeContract {
    public static let expectedABIVersion: UInt32 = 2
    public static let expectedRuntimeVersion = "0.1.0-alpha.2"
    public static let expectedSuiteID = Array("ML-KEM-768+X25519".utf8)

    private static let validationResult = validateRuntime()

    public static var isCompatible: Bool {
        if case .success = validationResult {
            return true
        }
        return false
    }

    public static func requireCompatible() throws {
        try validationResult.get()
    }

    public static func statusDescription(_ status: Int32) -> String {
        guard let statusPointer = q_periapt_status_name(status) else {
            return "status=\(status)"
        }
        return "\(String(cString: statusPointer)) (\(status))"
    }

    private static func validateRuntime() -> Result<Void, QPeriaptRuntimeContractError> {
        let runtimeABI = q_periapt_abi_version()
        guard runtimeABI == expectedABIVersion else {
            return .failure(
                .abiMismatch(expected: expectedABIVersion, actual: runtimeABI)
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
            return .failure(.frozenHeaderContractChanged)
        }

        let runtimeSuiteLength = Int(q_periapt_fixed_suite_id_len())
        guard runtimeSuiteLength == expectedSuiteID.count,
              let suitePointer = q_periapt_fixed_suite_id() else {
            return .failure(.invalidSuiteMetadata)
        }
        let runtimeSuiteID = Array(
            UnsafeRawBufferPointer(
                start: UnsafeRawPointer(suitePointer),
                count: runtimeSuiteLength
            )
        )
        guard runtimeSuiteID == expectedSuiteID else {
            return .failure(.suiteMismatch)
        }

        guard let versionPointer = q_periapt_version() else {
            return .failure(.missingRuntimeVersion)
        }
        let runtimeVersion = String(cString: versionPointer)
        guard runtimeVersion == expectedRuntimeVersion else {
            return .failure(
                .runtimeVersionMismatch(
                    expected: expectedRuntimeVersion,
                    actual: runtimeVersion
                )
            )
        }
        return .success(())
    }
}
