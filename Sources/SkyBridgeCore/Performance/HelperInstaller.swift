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
    /// SMAppService.daemon(plistName:) 需要完整 plist 文件名（含扩展名）
    private static let helperPlistName = "com.skybridge.PowerMetricsHelper.plist"

    /// 存储最后一次错误信息
    private static var lastError: String?
    private static var lastInstallAttemptAt: Date = .distantPast
    private static var lastUninstallAttemptAt: Date = .distantPast
    private static let installCooldown: TimeInterval = 30
    private static let uninstallCooldown: TimeInterval = 15

    private struct HelperPaths {
        let bundlePath: String
        let launchDaemonsDir: String
        let plistPath: String
        let helperDir: String
        let executablePath: String
        let isPackagedApp: Bool
    }

    /// 获取最后一次错误信息
    static func getLastError() -> String? {
        return lastError
    }

    /// 检查 Helper 是否已安装并启用
    static func isHelperInstalled() -> Bool {
        let paths = resolveHelperPaths()
        if !paths.isPackagedApp {
            logger.info("ℹ️ 当前非 .app 打包运行环境，跳过 Helper 状态检查")
            return false
        }
        prepareDevelopmentHelperFilesIfNeeded(paths: paths)

        // 先检查 plist 文件是否存在，避免在文件不存在时触发系统错误弹窗
        if !FileManager.default.fileExists(atPath: paths.plistPath) {
            logger.info("ℹ️ Helper plist 文件不存在，跳过状态检查: \(paths.plistPath)")
            return false
        }

        // 使用 SMAppService 查询状态（daemon 用于特权 Helper）
        // plistName 需要传入完整文件名（含 .plist）
        let service = SMAppService.daemon(plistName: helperPlistName)
        return service.status == SMAppService.Status.enabled
    }

    /// 安装 Helper（注册到系统）
    /// Helper 必须已内嵌在 App bundle 的 Contents/Library/LaunchDaemons/ 目录
    static func installHelper() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastInstallAttemptAt) < installCooldown {
            logger.info("⏱️ 安装请求命中冷却窗口，跳过重复安装")
            return isHelperInstalled()
        }
        lastInstallAttemptAt = now

        let paths = resolveHelperPaths()
        if !paths.isPackagedApp {
            let errorMsg = """
            当前运行的是 Xcode 直跑产物（非 .app）。
            SMAppService 特权 Helper 需要签名后的应用包，请先运行 Scripts/run_app.sh，或执行 Scripts/package_app.sh + Scripts/sign_app.sh 后从 dist 目录启动应用再安装。
            """
            lastError = errorMsg
            logger.error("❌ \(errorMsg)")
            return false
        }

        // 先检查 plist 文件是否存在
        if !verifyHelperFiles() {
            return false
        }

        // 创建 SMAppService 实例（daemon 用于特权 Helper）
        let service = SMAppService.daemon(plistName: helperPlistName)

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
                return false // 需要批准时返回 false
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

            let paths = resolveHelperPaths()
            if !paths.isPackagedApp {
                fullError += "\n提示：当前运行的是 Xcode 直跑产物（非 .app），建议先运行 Scripts/run_app.sh 或 Scripts/package_app.sh 后再安装。"
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
        let paths = resolveHelperPaths()
        prepareDevelopmentHelperFilesIfNeeded(paths: paths)

        let fm = FileManager.default

        // 检查 plist 文件
        if !fm.fileExists(atPath: paths.plistPath) {
            let errorMsg = "未找到 launchd plist 文件: \(paths.plistPath)\(developmentModeHintIfNeeded(paths: paths))"
            lastError = errorMsg
            logger.error("❌ \(errorMsg)")
            return false
        }

        // 检查 Helper 可执行文件
        if !fm.fileExists(atPath: paths.executablePath) {
            let errorMsg = "未找到 Helper 可执行文件: \(paths.executablePath)\(developmentModeHintIfNeeded(paths: paths))"
            lastError = errorMsg
            logger.error("❌ \(errorMsg)")
            return false
        }

        // 检查可执行权限
        if !fm.isExecutableFile(atPath: paths.executablePath) {
            let errorMsg = "Helper 可执行文件没有执行权限: \(paths.executablePath)"
            lastError = errorMsg
            logger.error("❌ \(errorMsg)")
            return false
        }

        logger.info("✅ Helper 文件验证通过")
        return true
    }

    private static func resolveHelperPaths() -> HelperPaths {
        let bundlePath = Bundle.main.bundlePath
        let launchDaemonsDir = "\(bundlePath)/Contents/Library/LaunchDaemons"
        let plistPath = "\(launchDaemonsDir)/\(helperServiceName).plist"
        let helperDir = "\(launchDaemonsDir)/\(helperServiceName)"
        let executablePath = "\(helperDir)/\(helperServiceName)"
        let isPackagedApp = bundlePath.hasSuffix(".app")

        return HelperPaths(
            bundlePath: bundlePath,
            launchDaemonsDir: launchDaemonsDir,
            plistPath: plistPath,
            helperDir: helperDir,
            executablePath: executablePath,
            isPackagedApp: isPackagedApp
        )
    }

    private static func developmentModeHintIfNeeded(paths: HelperPaths) -> String {
        guard !paths.isPackagedApp else { return "" }
        return "\n（当前运行的是 Xcode 直跑产物，请先构建 PowerMetricsHelper 或运行 Scripts/run_app.sh）"
    }

    private static func prepareDevelopmentHelperFilesIfNeeded(paths: HelperPaths) {
        guard !paths.isPackagedApp else { return }

        let fm = FileManager.default
        let missingPlist = !fm.fileExists(atPath: paths.plistPath)
        let missingExecutable = !fm.fileExists(atPath: paths.executablePath)
        guard missingPlist || missingExecutable else { return }

        do {
            try fm.createDirectory(atPath: paths.helperDir, withIntermediateDirectories: true)
        } catch {
            logger.warning("⚠️ 无法创建开发态 Helper 目录: \(error.localizedDescription)")
            return
        }

        if missingPlist {
            _ = stageLaunchdPlist(to: paths.plistPath)
        }

        if missingExecutable {
            let staged = stageHelperExecutable(to: paths.executablePath, bundlePath: paths.bundlePath)
            if staged {
                do {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.executablePath)
                } catch {
                    logger.warning("⚠️ 无法设置 Helper 可执行权限: \(error.localizedDescription)")
                }
            }
        }
    }

    @discardableResult
    private static func stageLaunchdPlist(to destinationPath: String) -> Bool {
        let fm = FileManager.default
        for sourcePath in launchdPlistSourceCandidates() where fm.fileExists(atPath: sourcePath) {
            do {
                try copyReplacingIfNeeded(from: sourcePath, to: destinationPath)
                logger.info("✅ 已准备 launchd plist（开发态）: \(destinationPath)")
                return true
            } catch {
                logger.warning("⚠️ 拷贝 launchd plist 失败: \(error.localizedDescription)")
            }
        }

        do {
            try defaultLaunchdPlist.write(toFile: destinationPath, atomically: true, encoding: .utf8)
            logger.info("✅ 已写入默认 launchd plist（开发态）: \(destinationPath)")
            return true
        } catch {
            logger.warning("⚠️ 写入默认 launchd plist 失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private static func stageHelperExecutable(to destinationPath: String, bundlePath: String) -> Bool {
        let fm = FileManager.default
        for sourcePath in helperExecutableSourceCandidates(bundlePath: bundlePath) where fm.fileExists(atPath: sourcePath) {
            do {
                try copyReplacingIfNeeded(from: sourcePath, to: destinationPath)
                logger.info("✅ 已准备 Helper 可执行文件（开发态）: \(destinationPath)")
                return true
            } catch {
                logger.warning("⚠️ 拷贝 Helper 可执行文件失败: \(error.localizedDescription)")
            }
        }
        return false
    }

    private static func launchdPlistSourceCandidates() -> [String] {
        var candidates: [String] = []

        if let bundled = Bundle.main.path(forResource: helperServiceName, ofType: "plist") {
            candidates.append(bundled)
        }

        let cwd = FileManager.default.currentDirectoryPath
        candidates.append("\(cwd)/Sources/PowerMetricsHelper/\(helperServiceName).plist")

        return deduplicated(candidates)
    }

    private static func helperExecutableSourceCandidates(bundlePath: String) -> [String] {
        var candidates: [String] = [
            "\(bundlePath)/PowerMetricsHelper"
        ]

        if bundlePath.contains("/Release") {
            candidates.append(bundlePath.replacingOccurrences(of: "/Release", with: "/Debug") + "/PowerMetricsHelper")
        }

        if let builtProductsDir = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"], !builtProductsDir.isEmpty {
            candidates.append("\(builtProductsDir)/PowerMetricsHelper")
        }

        let cwd = FileManager.default.currentDirectoryPath
        candidates.append("\(cwd)/.build/xcode/Build/Products/Release/PowerMetricsHelper")
        candidates.append("\(cwd)/.build/xcode/Build/Products/Debug/PowerMetricsHelper")

        return deduplicated(candidates)
    }

    private static func deduplicated(_ candidates: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates where !candidate.isEmpty {
            if seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private static func copyReplacingIfNeeded(from sourcePath: String, to destinationPath: String) throws {
        let fm = FileManager.default
        let destinationDir = URL(fileURLWithPath: destinationPath).deletingLastPathComponent().path
        try fm.createDirectory(atPath: destinationDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationPath) {
            try fm.removeItem(atPath: destinationPath)
        }
        try fm.copyItem(atPath: sourcePath, toPath: destinationPath)
    }

    private static var defaultLaunchdPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(helperServiceName)</string>
            <key>BundleProgram</key>
            <string>Contents/Library/LaunchDaemons/\(helperServiceName)/\(helperServiceName)</string>
            <key>MachServices</key>
            <dict>
                <key>\(helperServiceName)</key>
                <true/>
            </dict>
        </dict>
        </plist>
        """
    }

    /// 卸载 Helper
    static func uninstallHelper() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastUninstallAttemptAt) < uninstallCooldown {
            logger.info("⏱️ 卸载请求命中冷却窗口，跳过重复卸载")
            return true
        }
        lastUninstallAttemptAt = now

        // 创建 SMAppService 实例（daemon 用于特权 Helper）
        let service = SMAppService.daemon(plistName: helperPlistName)

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
