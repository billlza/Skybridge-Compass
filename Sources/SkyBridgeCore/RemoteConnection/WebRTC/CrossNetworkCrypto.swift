import Foundation
import CryptoKit

/// 跨网传输加密原语（SHA-256 / 未来可扩展 HKDF 等）。
///
/// 设计原则（IEEE TDSC §IV-B）：
/// - 使用 Apple CryptoKit 以获得硬件加速与恒定时间保证。
/// - 返回值统一为非可选 `Data`，与 iOS 侧 `CrossNetworkCryptoCompat` 保持一致，
///   避免调用方在完整性校验路径上引入 `nil` 分支。
enum CrossNetworkCrypto {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
