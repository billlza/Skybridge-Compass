import Foundation
import Network

/// TLS 配置器：根据设置中的加密算法选择生成 TLS 选项
/// 中文说明：本组件用于统一近距/远程路径的 TLS 策略，确保加密版本与握手参数一致。
public enum TLSConfigurator {
 /// 根据加密算法选择生成 TLS 选项；none 返回 nil。
    public static func options(for algorithm: EncryptionAlgorithm) -> NWProtocolTLS.Options? {
        switch algorithm {
        case .none:
            return nil
        case .tls12:
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            return tls
        case .tls13:
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            return tls
        }
    }
}