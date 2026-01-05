import SwiftUI
import os.log

/// API密钥管理视图 - 安全管理所有API密钥和敏感配置
public struct APIKeyManagementView: View {
    
 // MARK: - 状态属性
    
    @State private var weatherAPIKey = ""
    @State private var supabaseURL = ""
    @State private var supabaseAnonKey = ""
    @State private var supabaseServiceKey = ""
    @State private var nebulaClientID = ""
    @State private var nebulaClientSecret = ""
    @State private var smsAccessKeyID = ""
    @State private var smsAccessKeySecret = ""
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    @Environment(\.dismiss) private var dismiss
    
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "APIKeyManagementView")
    
 // MARK: - 主界面
    
    public var body: some View {
        NavigationView {
            List {
 // 天气服务配置
                Section("天气服务") {
                    APIKeyRow(
                        title: "API密钥",
                        value: $weatherAPIKey,
                        placeholder: "输入天气API密钥",
                        onSave: { key in
                            Task {
                                await saveWeatherAPIKey(key)
                            }
                        }
                    )
                }
                
 // Supabase配置
                Section("Supabase配置") {
                    APIKeyRow(
                        title: "URL",
                        value: $supabaseURL,
                        placeholder: "输入Supabase URL",
                        onSave: { url in
                            Task {
                                await saveSupabaseConfig()
                            }
                        }
                    )
                    
                    APIKeyRow(
                        title: "匿名密钥",
                        value: $supabaseAnonKey,
                        placeholder: "输入匿名密钥",
                        onSave: { key in
                            Task {
                                await saveSupabaseConfig()
                            }
                        }
                    )
                    
                    APIKeyRow(
                        title: "服务密钥",
                        value: $supabaseServiceKey,
                        placeholder: "输入服务密钥",
                        onSave: { key in
                            Task {
                                await saveSupabaseConfig()
                            }
                        }
                    )
                }
                
 // Nebula配置
                Section("Nebula配置") {
                    APIKeyRow(
                        title: "客户端ID",
                        value: $nebulaClientID,
                        placeholder: "输入Nebula客户端ID",
                        onSave: { id in
                            Task {
                                await saveNebulaConfig()
                            }
                        }
                    )
                    
                    APIKeyRow(
                        title: "客户端密钥",
                        value: $nebulaClientSecret,
                        placeholder: "输入Nebula客户端密钥",
                        onSave: { secret in
                            Task {
                                await saveNebulaConfig()
                            }
                        }
                    )
                }
                
 // SMS服务配置
                Section("SMS服务配置") {
                    APIKeyRow(
                        title: "访问密钥ID",
                        value: $smsAccessKeyID,
                        placeholder: "输入SMS访问密钥ID",
                        onSave: { id in
                            Task {
                                await saveSMSConfig()
                            }
                        }
                    )
                    
                    APIKeyRow(
                        title: "访问密钥Secret",
                        value: $smsAccessKeySecret,
                        placeholder: "输入SMS访问密钥Secret",
                        onSave: { secret in
                            Task {
                                await saveSMSConfig()
                            }
                        }
                    )
                }
                
 // 管理操作
                Section("管理操作") {
                    Button(action: {
                        Task {
                            await migrateFromEnvironment()
                        }
                    }) {
                        HStack {
                            Image(systemName: "arrow.up.doc")
                            Text("从环境变量迁移配置")
                        }
                        .foregroundColor(.blue)
                    }
                    
                    Button(action: {
                        Task {
                            await clearAllAPIKeys()
                        }
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("清除所有API密钥")
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("API密钥管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            Task {
                await loadCurrentAPIKeys()
            }
        }
        .alert("操作结果", isPresented: $showingAlert) {
            Button("确定") { }
        } message: {
            Text(alertMessage)
        }
    }
    
 // MARK: - API密钥管理方法
    
    private func loadCurrentAPIKeys() async {
 // 加载当前保存的API密钥（不显示实际值，只显示是否已配置）
        let keychain = KeychainManager.shared
        
        await MainActor.run {
            do {
                _ = try keychain.retrieveWeatherAPIKey()
                weatherAPIKey = "••••••••"
            } catch {
                weatherAPIKey = ""
            }
            
            do {
                let supabaseConfig = try keychain.retrieveSupabaseConfig()
                supabaseURL = supabaseConfig.url.isEmpty ? "" : "••••••••"
                supabaseAnonKey = supabaseConfig.anonKey.isEmpty ? "" : "••••••••"
                supabaseServiceKey = supabaseConfig.serviceRoleKey?.isEmpty == false ? "••••••••" : ""
            } catch {
                supabaseURL = ""
                supabaseAnonKey = ""
                supabaseServiceKey = ""
            }
            
            do {
                let nebulaConfig = try keychain.retrieveNebulaConfig()
                nebulaClientID = nebulaConfig.clientId.isEmpty ? "" : "••••••••"
                nebulaClientSecret = nebulaConfig.clientSecret.isEmpty ? "" : "••••••••"
            } catch {
                nebulaClientID = ""
                nebulaClientSecret = ""
            }
            
            do {
                let smsConfig = try keychain.retrieveSMSConfig()
                smsAccessKeyID = smsConfig.accessKeyId.isEmpty ? "" : "••••••••"
                smsAccessKeySecret = smsConfig.accessKeySecret.isEmpty ? "" : "••••••••"
            } catch {
                smsAccessKeyID = ""
                smsAccessKeySecret = ""
            }
        }
    }
    
    private func saveWeatherAPIKey(_ key: String) async {
        guard !key.isEmpty else { return }
        
        let keychain = KeychainManager.shared
        
        await MainActor.run {
            do {
                try keychain.storeWeatherAPIKey(key)
                alertMessage = "天气API密钥保存成功"
                logger.info("天气API密钥已保存到Keychain")
            } catch {
                alertMessage = "天气API密钥保存失败: \(error.localizedDescription)"
                logger.error("天气API密钥保存到Keychain失败: \(error.localizedDescription)")
            }
            showingAlert = true
        }
        
        await loadCurrentAPIKeys()
    }
    
    private func saveSupabaseConfig() async {
        let keychain = KeychainManager.shared
        
        await MainActor.run {
            do {
 // 获取当前配置用于保留未修改的值
                var currentURL = ""
                var currentAnonKey = ""
                var currentServiceKey: String? = nil
                
                if let currentConfig = try? keychain.retrieveSupabaseConfig() {
                    currentURL = currentConfig.url
                    currentAnonKey = currentConfig.anonKey
                    currentServiceKey = currentConfig.serviceRoleKey
                }
                
                let finalURL = supabaseURL == "••••••••" ? currentURL : supabaseURL
                let finalAnonKey = supabaseAnonKey == "••••••••" ? currentAnonKey : supabaseAnonKey
                let finalServiceKey = supabaseServiceKey == "••••••••" ? currentServiceKey : (supabaseServiceKey.isEmpty ? nil : supabaseServiceKey)
                
                try keychain.storeSupabaseConfig(url: finalURL, anonKey: finalAnonKey, serviceRoleKey: finalServiceKey)
                alertMessage = "Supabase配置保存成功"
                logger.info("Supabase配置已保存到Keychain")
            } catch {
                alertMessage = "Supabase配置保存失败: \(error.localizedDescription)"
                logger.error("Supabase配置保存到Keychain失败: \(error.localizedDescription)")
            }
            showingAlert = true
        }
        
        await loadCurrentAPIKeys()
    }
    
    private func saveNebulaConfig() async {
        let keychain = KeychainManager.shared
        
        await MainActor.run {
            do {
 // 获取当前配置用于保留未修改的值
                var currentClientId = ""
                var currentClientSecret = ""
                
                if let currentConfig = try? keychain.retrieveNebulaConfig() {
                    currentClientId = currentConfig.clientId
                    currentClientSecret = currentConfig.clientSecret
                }
                
                let finalClientId = nebulaClientID == "••••••••" ? currentClientId : nebulaClientID
                let finalClientSecret = nebulaClientSecret == "••••••••" ? currentClientSecret : nebulaClientSecret
                
                try keychain.storeNebulaConfig(clientId: finalClientId, clientSecret: finalClientSecret)
                alertMessage = "Nebula配置保存成功"
                logger.info("Nebula配置已保存到Keychain")
            } catch {
                alertMessage = "Nebula配置保存失败: \(error.localizedDescription)"
                logger.error("Nebula配置保存到Keychain失败: \(error.localizedDescription)")
            }
            showingAlert = true
        }
        
        await loadCurrentAPIKeys()
    }
    
    private func saveSMSConfig() async {
        let keychain = KeychainManager.shared
        
        await MainActor.run {
            do {
 // 获取当前配置用于保留未修改的值
                var currentAccessKeyId = ""
                var currentAccessKeySecret = ""
                
                if let currentConfig = try? keychain.retrieveSMSConfig() {
                    currentAccessKeyId = currentConfig.accessKeyId
                    currentAccessKeySecret = currentConfig.accessKeySecret
                }
                
                let finalAccessKeyId = smsAccessKeyID == "••••••••" ? currentAccessKeyId : smsAccessKeyID
                let finalAccessKeySecret = smsAccessKeySecret == "••••••••" ? currentAccessKeySecret : smsAccessKeySecret
                
                try keychain.storeSMSConfig(accessKeyId: finalAccessKeyId, accessKeySecret: finalAccessKeySecret)
                alertMessage = "SMS配置保存成功"
                logger.info("SMS配置已保存到Keychain")
            } catch {
                alertMessage = "SMS配置保存失败: \(error.localizedDescription)"
                logger.error("SMS配置保存到Keychain失败: \(error.localizedDescription)")
            }
            showingAlert = true
        }
        
        await loadCurrentAPIKeys()
    }
    
    private func migrateFromEnvironment() async {
        let keychain = KeychainManager.shared
        var migratedCount = 0
        
 // 迁移天气API密钥
        if let weatherKey = ProcessInfo.processInfo.environment["WEATHER_API_KEY"], !weatherKey.isEmpty {
            do {
                try keychain.storeWeatherAPIKey(weatherKey)
                migratedCount += 1
            } catch {
                logger.error("迁移天气API密钥失败: \(error.localizedDescription)")
            }
        }
        
 // 迁移Supabase配置
        let supabaseURL = ProcessInfo.processInfo.environment["SUPABASE_URL"] ?? ""
        let supabaseAnonKey = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] ?? ""
        let supabaseServiceKey = ProcessInfo.processInfo.environment["SUPABASE_SERVICE_ROLE_KEY"] ?? ""
        
        if !supabaseURL.isEmpty && !supabaseAnonKey.isEmpty {
            do {
                try keychain.storeSupabaseConfig(url: supabaseURL, anonKey: supabaseAnonKey, serviceRoleKey: supabaseServiceKey.isEmpty ? nil : supabaseServiceKey)
                migratedCount += 1
            } catch {
                logger.error("迁移Supabase配置失败: \(error.localizedDescription)")
            }
        }
        
 // 迁移Nebula配置
        let nebulaClientID = ProcessInfo.processInfo.environment["NEBULA_CLIENT_ID"] ?? ""
        let nebulaClientSecret = ProcessInfo.processInfo.environment["NEBULA_CLIENT_SECRET"] ?? ""
        
        if !nebulaClientID.isEmpty && !nebulaClientSecret.isEmpty {
            do {
                try keychain.storeNebulaConfig(clientId: nebulaClientID, clientSecret: nebulaClientSecret)
                migratedCount += 1
            } catch {
                logger.error("迁移Nebula配置失败: \(error.localizedDescription)")
            }
        }
        
 // 迁移SMS配置
        let smsAccessKeyID = ProcessInfo.processInfo.environment["SMS_ACCESS_KEY_ID"] ?? ""
        let smsAccessKeySecret = ProcessInfo.processInfo.environment["SMS_ACCESS_KEY_SECRET"] ?? ""
        
        if !smsAccessKeyID.isEmpty && !smsAccessKeySecret.isEmpty {
            do {
                try keychain.storeSMSConfig(accessKeyId: smsAccessKeyID, accessKeySecret: smsAccessKeySecret)
                migratedCount += 1
            } catch {
                logger.error("迁移SMS配置失败: \(error.localizedDescription)")
            }
        }
        
        await MainActor.run {
            alertMessage = "成功迁移 \(migratedCount) 个配置项到安全存储"
            logger.info("从环境变量迁移了 \(migratedCount) 个配置项到Keychain")
            showingAlert = true
        }
        
        await loadCurrentAPIKeys()
    }
    
    private func clearAllAPIKeys() async {
        let keychain = KeychainManager.shared
        var clearedCount = 0
        
        do {
            try keychain.deleteAPIKey(service: "SkyBridge.Weather", account: "OpenWeatherMap")
            clearedCount += 1
        } catch {
            logger.warning("删除天气API密钥失败: \(error.localizedDescription)")
        }
        
        do {
            try keychain.deleteAPIKey(service: "SkyBridge.Supabase", account: "URL")
            try keychain.deleteAPIKey(service: "SkyBridge.Supabase", account: "AnonKey")
            try keychain.deleteAPIKey(service: "SkyBridge.Supabase", account: "ServiceRoleKey")
            clearedCount += 1
        } catch {
            logger.warning("删除Supabase配置失败: \(error.localizedDescription)")
        }
        
        do {
            try keychain.deleteAPIKey(service: "SkyBridge.Nebula", account: "ClientId")
            try keychain.deleteAPIKey(service: "SkyBridge.Nebula", account: "ClientSecret")
            clearedCount += 1
        } catch {
            logger.warning("删除Nebula配置失败: \(error.localizedDescription)")
        }
        
        do {
            try keychain.deleteAPIKey(service: "SkyBridge.SMS", account: "AccessKeyId")
            try keychain.deleteAPIKey(service: "SkyBridge.SMS", account: "AccessKeySecret")
            clearedCount += 1
        } catch {
            logger.warning("删除SMS配置失败: \(error.localizedDescription)")
        }
        
        await MainActor.run {
            alertMessage = "已清除 \(clearedCount) 个API密钥配置"
            showingAlert = true
            
 // 清空界面显示
            weatherAPIKey = ""
            supabaseURL = ""
            supabaseAnonKey = ""
            supabaseServiceKey = ""
            nebulaClientID = ""
            nebulaClientSecret = ""
            smsAccessKeyID = ""
            smsAccessKeySecret = ""
        }
    }
}

// MARK: - API密钥输入行组件

private struct APIKeyRow: View {
    let title: String
    @Binding var value: String
    let placeholder: String
    let onSave: (String) -> Void
    
    @State private var isEditing = false
    @State private var editingValue = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                if isEditing {
                    HStack {
                        Button("取消") {
                            isEditing = false
                            editingValue = ""
                        }
                        .foregroundColor(.secondary)
                        
                        Button("保存") {
                            onSave(editingValue)
                            value = editingValue.isEmpty ? "" : "••••••••"
                            isEditing = false
                            editingValue = ""
                        }
                        .foregroundColor(.blue)
                        .disabled(editingValue.isEmpty)
                    }
                } else {
                    Button(value.isEmpty ? "添加" : "编辑") {
                        isEditing = true
                        editingValue = value == "••••••••" ? "" : value
                    }
                    .foregroundColor(.blue)
                }
            }
            
            if isEditing {
                SecureField(placeholder, text: $editingValue)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            } else if !value.isEmpty {
                Text(value)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 预览

#if DEBUG
struct APIKeyManagementView_Previews: PreviewProvider {
    static var previews: some View {
        APIKeyManagementView()
    }
}
#endif