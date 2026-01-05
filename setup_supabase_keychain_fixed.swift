import Foundation
import Security

// 使用正确的 service 名称配置 Keychain
// 必须与 KeychainManager 中的名称一致！

func storeInKeychain(service: String, account: String, value: String) -> Bool {
    let data = value.data(using: .utf8)!
    
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        kSecValueData as String: data
    ]
    
    // 先删除旧值
    SecItemDelete(query as CFDictionary)
    
    // 添加新值
    let status = SecItemAdd(query as CFDictionary, nil)
    
    if status == errSecSuccess {
        print("✅ 成功存储: \(account)")
        return true
    } else {
        print("❌ 存储失败: \(account) (错误码: \(status))")
        return false
    }
}

print("🔐 使用正确的 service 名称配置 Supabase Keychain 凭据...")
print("   Service: SkyBridge.Supabase")
print("")

let urlSuccess = storeInKeychain(
    service: "SkyBridge.Supabase",
    account: "URL",
    value: "https://hloqytmhjludmuhwyyzb.supabase.co"
)

let keySuccess = storeInKeychain(
    service: "SkyBridge.Supabase",
    account: "AnonKey",
    value: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb3F5dG1oamx1ZG11aHd5eXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUzNTE3ODUsImV4cCI6MjA3MDkyNzc4NX0.xmDCgBo5IpDlzIerIz7y2jruh34MEYrtcepeK3x_HT0"
)

print("")
if urlSuccess && keySuccess {
    print("🎉 Supabase 配置已成功保存到 Keychain！")
    print("   应用重启后会从 Keychain 自动加载")
    print("")
    print("   请完全退出应用并重新打开")
} else {
    print("⚠️  配置保存失败，请检查权限")
}
