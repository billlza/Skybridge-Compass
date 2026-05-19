import Foundation

enum P2PHandshakeErrorFormatter {
    static func localizedMessage(for error: Error) -> String {
        if let reason = handshakeFailureReason(from: error) {
            return localizedMessage(for: reason)
        }

        if isCryptoKitAEADFailure(error) {
            return localizedMessage(for: .cryptoError(error.localizedDescription))
        }

        let detail = error.localizedDescription.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return "连接失败"
        }

        return simplifyTechnicalMessage(detail)
    }

    static func isLikelyStalePeerKEMCryptoFailure(_ error: Error) -> Bool {
        if isCryptoKitAEADFailure(error) {
            return true
        }

        guard let reason = handshakeFailureReason(from: error) else {
            return false
        }

        if case .cryptoError(let detail) = reason {
            return isAEADFailureDetail(detail)
        }
        return false
    }

    private static func localizedMessage(for reason: HandshakeFailureReason) -> String {
        switch reason {
        case .timeout:
            return "连接超时 - 对方设备未响应"
        case .peerRejected(let message):
            return message.isEmpty ? "对方拒绝了连接请求" : "对方拒绝连接：\(message)"
        case .cryptoError(let detail):
            if isAEADFailureDetail(detail) {
                return "安全验证失败：解密认证失败（可能是对端 PQC KEM 公钥已变更或缓存失效）。当前已中止连接，不会降级或假装成功；请重新完成受信任设备验证后重试。"
            }
            return "安全验证失败：\(simplifyTechnicalMessage(detail))"
        case .transportError(let detail):
            return "网络传输错误：\(simplifyTechnicalMessage(detail))"
        case .cancelled:
            return "连接已取消"
        case .versionMismatch(let local, let remote):
            return "协议版本不兼容（本地 v\(local)，对方 v\(remote)），请更新应用"
        case .suiteNegotiationFailed:
            return "无法协商安全加密方式 - 两台设备的加密能力不匹配"
        case .signatureVerificationFailed:
            return "身份验证失败 - 对方设备的身份无法验证"
        case .invalidMessageFormat:
            return "收到无效的握手消息 - 可能是版本不兼容"
        case .identityMismatch(let expected, _):
            return "设备身份不匹配 - 期望连接到「\(expected)」但对方身份不符"
        case .replayDetected:
            return "检测到重放攻击，连接已中止"
        case .secureEnclavePoPRequired:
            return "此连接需要安全芯片验证，但对方设备不支持"
        case .secureEnclaveSignatureInvalid:
            return "安全芯片验证失败"
        case .keyConfirmationFailed:
            return "密钥确认失败 - 安全通道建立失败"
        case .suiteSignatureMismatch(let suite, _):
            return "安全配置不匹配（\(simplifyTechnicalMessage(suite))）"
        case .pqcProviderUnavailable:
            return "后量子加密不可用 - 需要 macOS 26/iOS 26 或更高版本"
        case .missingPeerKEMPublicKey(let suite):
            return "缺少对端后量子密钥材料（\(simplifyTechnicalMessage(suite))），无法建立 PQC 握手。当前已中止连接，不会降级或假装成功；请重新完成受信任设备验证后重试。"
        case .suiteNotSupported:
            return "不支持的加密套件 - 请更新应用"
        case .supersededByConcurrentAttempt:
            return "检测到并发连接，本次连接已被新尝试取代"
        case .unknownSuite(let wireId):
            return "检测到未知加密套件（ID: \(wireId)）"
        }
    }

    private static func simplifyTechnicalMessage(_ message: String) -> String {
        var simplified = message
        let prefixesToRemove = [
            "Error Domain=",
            "Code=",
            "NSError:",
            "Swift.DecodingError.",
            "CryptoKit."
        ]

        for prefix in prefixesToRemove {
            if let range = simplified.range(of: prefix),
               let endIndex = simplified[range.upperBound...].firstIndex(where: { $0 == " " || $0 == ":" }) {
                simplified.removeSubrange(range.lowerBound..<simplified.index(after: endIndex))
            }
        }

        if simplified.count > 100 {
            simplified = String(simplified.prefix(100)) + "..."
        }

        return simplified.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    private static func handshakeFailureReason(from error: Error) -> HandshakeFailureReason? {
        if let reason = error as? HandshakeFailureReason {
            return reason
        }
        if let handshakeError = error as? HandshakeError,
           case .failed(let reason) = handshakeError {
            return reason
        }
        return nil
    }

    private static func isCryptoKitAEADFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        let haystack = [
            nsError.domain,
            nsError.localizedDescription,
            nsError.userInfo[NSDebugDescriptionErrorKey] as? String,
            String(describing: error),
            String(reflecting: type(of: error))
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        guard haystack.contains("cryptokit") else {
            return false
        }

        return haystack.contains("error 3")
            || haystack.contains("错误3")
            || haystack.contains("错误 3")
    }

    private static func isAEADFailureDetail(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        if lowered.contains("messagebpayloadauthenticationfailed")
            || lowered.contains("aead authentication failed") {
            return true
        }

        if lowered.contains("cryptokiterror error 3")
            || lowered.contains("cryptokit.cryptokiterror error 3") {
            return true
        }

        return (detail.contains("错误3") || detail.contains("错误 3"))
            && detail.contains("未能完成操作")
    }
}
