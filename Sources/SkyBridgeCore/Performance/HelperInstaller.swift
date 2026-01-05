import Foundation
import ServiceManagement
import os.log

/// 使用现代 SMAppService API（macOS 13+）管理特权 Helper
/// 完全替代已弃用的 SMJobBless
@available(macOS 14.0, *)
@MainActor
enum HelperInstaller {
 /// 专用日志器
    private static let logger = Logger(subsystem: SkyBridgeLogger.subsystem, category: "HelperInstaller")
 /// Helper 的标识符（与 launchd plist 中的 Label 一致）
    static let helperServiceName = "com.skybridge.PowerMetricsHelper"
    
 /// 存储最后一次错误信息
    private static var lastError: String?
    
 /// 获取最后一次错误信息
    static func getLastError() -> String? {
        return lastError
    }

 /// 检查 Helper 是否已安装并启用
    static func isHelperInstalled() -> Bool {
 // 先检查 plist 文件是否存在，避免在文件不存在时触发系统错误弹窗
        guard let bundlePath = Bundle.main.bundlePath as String? else {
            logger.warning("⚠️ 无法获取 App bundle 路径，跳过 Helper 状态检查")
            return false
        }
        
        let plistPath = "\(bundlePath)/Contents/Library/LaunchDaemons/\(helperServiceName).plist"
        if !FileManager.default.fileExists(atPath: plistPath) {
            logger.info("ℹ️ Helper plist 文件不存在，跳过状态检查: \(plistPath)")
            return false
        }
        
 // 使用 SMAppService 查询状态（daemon 用于特权 Helper）
 // plistName 是 launchd plist 的文件名（不含扩展名）
        let service = SMAppService.daemon(plistName: helperServiceName)
        return service.status == SMAppService.Status.enabled
    }

 /// 安装 Helper（注册到系统）
 /// Helper 必须已内嵌在 App bundle 的 Contents/Library/LaunchDaemons/ 目录
    static func installHelper() -> Bool {
 // 先检查 plist 文件是否存在
        if !verifyHelperFiles() {
            return false
        }
        
 // 创建 SMAppService 实例（daemon 用于特权 Helper）
        let service = SMAppService.daemon(plistName: helperServiceName)
        
 // 检查当前状态
        switch service.status {
        case SMAppService.Status.enabled:
            logger.info("✅ Helper 已安装并启用")
            return true
        case SMAppService.Status.requiresApproval:
            logger.warning("⚠️ Helper 需要用户在系统设置中批准")
 // 打开系统设置页面
            SMAppService.openSystemSettingsLoginItems()
            return false
        case SMAppService.Status.notFound:
            logger.info("📦 Helper 未找到，开始注册...")
            break
        default:
            logger.warning("⚠️ Helper 状态: \(String(describing: service.status))")
            break
        }
        
 // 注册服务
        do {
            try service.register()
            lastError = nil
            logger.info("✅ Helper 注册成功，当前状态: \(String(describing: service.status))")
            
 // 检查最终状态
            if service.status == SMAppService.Status.requiresApproval {
                let msg = "Helper 需要用户在系统设置中批准"
                lastError = msg
                logger.warning("⚠️ \(msg)，正在打开系统设置...")
                SMAppService.openSystemSettingsLoginItems()
                return false  // 需要批准时返回 false
            }
            
            return true
        } catch {
            let errorDesc = error.localizedDescription
            var fullError = errorDesc
            
            if let nsError = error as NSError? {
                fullError += " (域: \(nsError.domain), 码: \(nsError.code))"
                let userInfo = nsError.userInfo
                let userInfoStr = userInfo.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                if !userInfoStr.isEmpty {
                    fullError += "\n详细信息: \(userInfoStr)"
                }
            }
            
            lastError = fullError
            logger.error("❌ Helper 注册失败: \(fullError)")
            SkyBridgeLogger.performance.error("❌ Helper 注册失败: \(fullError, privacy: .private)")
            return false
        }
    }
    
 /// 验证 Helper 文件是否存在于 App bundle 中
 /// 18.3: 移除 lastError! 使用，直接使用 lastError (Requirements 8.1)
    private static func verifyHelperFiles() -> Bool {
        guard let bundlePath = Bundle.main.bundlePath as String? else {
            let errorMsg = "无法获取 App bundle 路径"
            lastError = errorMsg
            logger.error("❌ \(errorMsg)")
            return false
        }
        
        let launchDaemonsDir = "\(bundlePath)/Contents/Library/LaunchDaemons"
        let plistPath = "\(launchDaemonsDir)/\(helperServiceName).plist"
        let helperDir = "\(launchDaemonsDir)/\(helperServiceName)"
        let executablePath = "\(helperDir)/\(helperServiceName)"
        
        let fm = FileManager.default
        
 // 检查 plist 文件
        if !fm.fileExists(atPath: plistPath) {
            let errorMsg = "未找到 launchd plist 文件: \(plistPath)"
            lastError = errorMsg
            logger.error("❌ \(errorMsg)")
            return false
        }
        
 // 检查 Helper 可执行文件
        if !fm.fileExists(atPath: executablePath) {
            let errorMsg = "未找到 Helper 可执行文件: \(executablePath)"
            lastError = errorMsg
            logger.error("❌ \(errorMsg)")
            return false
        }
        
 // 检查可执行权限
        if !fm.isExecutableFile(atPath: executablePath) {
            let errorMsg = "Helper 可执行文件没有执行权限: \(executablePath)"
            lastError = errorMsg
            logger.error("❌ \(errorMsg)")
            return false
        }
        
        logger.info("✅ Helper 文件验证通过")
        return true
    }

 /// 卸载 Helper
    static func uninstallHelper() -> Bool {
 // 创建 SMAppService 实例（daemon 用于特权 Helper）
        let service = SMAppService.daemon(plistName: helperServiceName)
        
 // 检查当前状态
        if service.status == SMAppService.Status.notFound {
            logger.info("ℹ️ Helper 未安装，无需卸载")
            return true
        }
        
 // 注销服务
        do {
            try service.unregister()
            logger.info("✅ Helper 卸载成功")
            return true
        } catch {
            logger.error("❌ Helper 卸载失败: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                logger.error("   错误域: \(nsError.domain), 错误码: \(nsError.code)")
            }
            return false
        }
    }
}
