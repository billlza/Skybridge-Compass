import Foundation
import CryptoKit

/// 对外暴露的便捷方法：为 RemoteDesktopManager 注入受信公钥提供者
@MainActor
public func SkyBridge_SetTrustedKeyProvider(_ provider: @escaping @Sendable () async -> [P256.Signing.PublicKey]) {
    RemoteDesktopManager.shared.setTrustedKeyProvider(provider)
}

/// 通过 Supabase REST 配置受信公钥提供者（public.user_devices.public_key）
@MainActor
public func SkyBridge_ConfigureTrustedKeysFromSupabase(url: String, anonKey: String, tenantId: String? = nil) {
    RemoteDesktopManager.shared.bootstrapTrustedKeysFromSupabase(url: url, anonKey: anonKey, tenantId: tenantId)
}


