import Foundation
import Security

// 直接配置 Keychain 中的 Supabase 凭据
// 这样应用启动时会自动加载，无需环境变量

let supabaseURL = "https://hloqytmhjludmuhwyyzb.supabase.co"
let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb3F5dG1oamx1ZG11aHd5eXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUzNTE3ODUsImV4cCI6MjA3MDkyNzc4NX0.xmDCgBo5IpDlzIerIz7y2jruh34MEYrtcepeK3x_HT0"

func storeInKeychain(account: String, value: String) -> Bool {
    let data = value.data(using: .utf8)!
    
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: account,
        kSecAttrService as String: "com.skybridge.compass.supabase",
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

print("🔐 配置 Supabase Keychain 凭据...")
print("")

let urlSuccess = storeInKeychain(account: "supabase_url", value: supabaseURL)
let keySuccess = storeInKeychain(account: "supabase_anon_key", value: supabaseAnonKey)

print("")
if urlSuccess && keySuccess {
    print("🎉 Supabase 配置已成功保存到 Keychain！")
    print("   应用重启后会自动加载这些配置")
    print("")
    print("   URL: \(supabaseURL)")
    print("   Key: \(String(supabaseAnonKey.prefix(50)))...")
} else {
    print("⚠️  部分配置保存失败，请检查权限")
}
