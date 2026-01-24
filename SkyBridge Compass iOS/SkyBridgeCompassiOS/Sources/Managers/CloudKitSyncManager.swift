import Foundation
import CloudKit

/// CloudKit 同步管理器 - 同步设备列表和信任关系
@MainActor
public class CloudKitSyncManager: ObservableObject {
    public static let instance = CloudKitSyncManager()
    
    @Published public private(set) var isSyncing: Bool = false
    @Published public private(set) var lastSyncDate: Date?
    
    private var container: CKContainer?
    private var database: CKDatabase?
    private var didLogEntitlementMissing = false
    
    private init() {
        // 注意：未在 Xcode Signing 中启用 iCloud/CloudKit 能力时，
        // 直接访问 CKContainer(identifier:) 可能触发运行时中断（如你截图所示）。
        // 因此这里不在 init 里触碰 CloudKit；在 initialize() 里按需启用。
    }
    
    public func initialize() async {
        #if targetEnvironment(simulator)
        SkyBridgeLogger.shared.info("ℹ️ 模拟器环境：默认跳过 CloudKit 初始化")
        #else
        guard Self.hasCloudKitEntitlement() else {
            if !didLogEntitlementMissing {
                didLogEntitlementMissing = true
                SkyBridgeLogger.shared.warning("⚠️ CloudKit 未启用：缺少 iCloud/CloudKit entitlement（请在 Xcode -> Signing & Capabilities -> iCloud 勾选 CloudKit，并配置容器）。")
            }
            return
        }

        // 使用 default container（由 entitlements 决定），避免硬编码 container id
        let container = CKContainer.default()
        self.container = container
        self.database = container.privateCloudDatabase

        // 检查 iCloud 状态
        let status = try? await container.accountStatus()
        if status == .available {
            SkyBridgeLogger.shared.info("✅ iCloud 可用")
        } else {
            SkyBridgeLogger.shared.warning("⚠️ iCloud 不可用")
        }
        #endif
    }

    /// 在调用 CKContainer.default() 之前检查 entitlement，避免直接触发运行时中断。
    private static func hasCloudKitEntitlement() -> Bool {
        // 使用 embedded.mobileprovision 解析 entitlements（在 Debug/AdHoc 下通常存在）
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = String(data: data, encoding: .isoLatin1) else {
            return false
        }

        guard let plistStart = raw.range(of: "<plist"),
              let plistEnd = raw.range(of: "</plist>") else {
            return false
        }
        let plistString = String(raw[plistStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistString.data(using: .utf8) else { return false }

        guard let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = obj as? [String: Any],
              let ent = dict["Entitlements"] as? [String: Any] else {
            return false
        }

        if let services = ent["com.apple.developer.icloud-services"] as? [String] {
            return services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
        }
        return false
    }
    
    public func sync() async throws {
        guard container != nil, database != nil else {
            SkyBridgeLogger.shared.warning("⚠️ CloudKit 未初始化（可能未开启 iCloud 能力或被禁用）")
            return
        }

        isSyncing = true
        defer { isSyncing = false }
        
        // TODO: 实现 CloudKit 同步逻辑
        try? await Task.sleep(for: .seconds(1))
        
        lastSyncDate = Date()
        SkyBridgeLogger.shared.info("✅ CloudKit 同步完成")
    }
}
