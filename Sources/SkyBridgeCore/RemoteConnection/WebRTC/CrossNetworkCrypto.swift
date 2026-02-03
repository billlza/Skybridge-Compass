import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

enum CrossNetworkCrypto {
    static func sha256(_ data: Data) -> Data? {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return Data(digest)
        #else
        return nil
        #endif
    }
}


