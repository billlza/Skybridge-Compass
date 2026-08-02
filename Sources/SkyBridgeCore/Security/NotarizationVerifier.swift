// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
//
// NotarizationVerifier.swift
// SkyBridgeCore
//
// Apple Notarization 验证模块
// 使用 spctl 命令验证公证状态，支持可替换后端
//

import Foundation
import OSLog

// MARK: - NotarizationResult

/// 公证验证结果
internal struct NotarizationResult: Sendable {
    let status: NotarizationStatus
    let source: String?  // "Notarized by Apple" 等
    let error: String?
    
    static func notarized(source: String? = "Apple Notarization") -> NotarizationResult {
        NotarizationResult(status: .notarized, source: source, error: nil)
    }
    
    static func notNotarized(error: String? = nil) -> NotarizationResult {
        NotarizationResult(status: .notNotarized, source: nil, error: error)
    }
    
    static func unknown(error: String) -> NotarizationResult {
        NotarizationResult(status: .unknown, source: nil, error: error)
    }
}

// MARK: - GatekeeperResult

/// Gatekeeper 评估结果
internal struct GatekeeperResult: Sendable {
    let assessment: GatekeeperAssessment
    let source: String?
    let error: String?
    
    static func allow(source: String? = nil) -> GatekeeperResult {
        GatekeeperResult(assessment: .allow, source: source, error: nil)
    }
    
    static func deny(error: String? = nil) -> GatekeeperResult {
        GatekeeperResult(assessment: .deny, source: nil, error: error)
    }
    
    static func unknown(error: String) -> GatekeeperResult {
        GatekeeperResult(assessment: .unknown, source: nil, error: error)
    }
}

// MARK: - NotarizationVerifying Protocol

/// 公证验证协议 - 便于后续切换实现
internal protocol NotarizationVerifying: Sendable {
    func verify(at url: URL) async -> NotarizationResult
    func assessGatekeeper(at url: URL) async -> GatekeeperResult
    func detectTargetType(at url: URL) async -> ScanTargetType
    func shouldCheckNotarization(at url: URL) async -> Bool
}

// MARK: - NotarizationVerifier Actor

/// 公证验证器
/// 使用 spctl 命令验证公证状态（当前实现，后续可切换）
internal actor NotarizationVerifier: NotarizationVerifying {
    
    private let logger = Logger(subsystem: "com.skybridge.security", category: "Notarization")
    
 /// 可注入的进程执行器（便于测试）
    private let processRunner: ProcessRunning
    
 /// Bundle 类型扩展名
    private let bundleExtensions: Set<String> = [
        "app", "pkg", "dmg", "plugin", "appex", "framework", "kext", "bundle"
    ]
    
 /// Archive 类型扩展名
    private let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"
    ]
    
    init(processRunner: ProcessRunning = DefaultProcessRunner()) {
        self.processRunner = processRunner
    }

    
 // MARK: - Public API
    
 /// 验证文件的公证状态
 /// - Parameter url: 文件 URL
 /// - Returns: 公证验证结果
    func verify(at url: URL) async -> NotarizationResult {
        logger.debug("🔏 验证公证状态: \(url.lastPathComponent)")
        
 // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: url.path) else {
            return NotarizationResult.unknown(error: "File not found")
        }
        
 // 使用 spctl 验证公证状态
        do {
 // spctl -a -v 用于验证 Gatekeeper 评估（包含公证信息）
            let result = try await processRunner.run(
                command: "/usr/sbin/spctl",
                arguments: ["-a", "-v", "--type", "execute", url.path]
            )
            
            return parseNotarizationResult(from: result)
            
        } catch {
            logger.error("❌ spctl 执行失败: \(error.localizedDescription)")
            return NotarizationResult.unknown(error: error.localizedDescription)
        }
    }
    
 /// 评估 Gatekeeper 状态
 /// - Parameter url: 文件 URL
 /// - Returns: Gatekeeper 评估结果
    func assessGatekeeper(at url: URL) async -> GatekeeperResult {
        logger.debug("🛡️ 评估 Gatekeeper: \(url.lastPathComponent)")
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            return GatekeeperResult.unknown(error: "File not found")
        }
        
        do {
 // spctl --assess 用于评估是否允许执行
            let result = try await processRunner.run(
                command: "/usr/sbin/spctl",
                arguments: ["--assess", "-v", url.path]
            )
            
            return parseGatekeeperResult(from: result)
            
        } catch {
            logger.error("❌ Gatekeeper 评估失败: \(error.localizedDescription)")
            return GatekeeperResult.unknown(error: error.localizedDescription)
        }
    }
    
 /// 判断扫描目标类型（三层判断）
 /// 1. Bundle: .app/.pkg/.dmg/.plugin/.appex（按 UTType）
 /// 2. Mach-O: 魔数判断 + 可执行位
 /// 3. Script: shebang #! + 可执行位
    func detectTargetType(at url: URL) async -> ScanTargetType {
        let fm = FileManager.default
        let ext = url.pathExtension.lowercased()
        
 // 1. 检查 Bundle 类型
        if bundleExtensions.contains(ext) {
            return .bundle
        }
        
 // 2. 检查 Archive 类型
        if archiveExtensions.contains(ext) {
            return .archive
        }
        
 // 3. 检查是否为目录
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
 // 检查是否为 bundle 目录（包含 Contents 或 Info.plist）
            let contentsPath = url.appendingPathComponent("Contents").path
            let infoPlistPath = url.appendingPathComponent("Info.plist").path
            if fm.fileExists(atPath: contentsPath) || fm.fileExists(atPath: infoPlistPath) {
                return .bundle
            }
            return .directory
        }
        
 // 4. 检查 Mach-O（魔数判断）
        if await isMachOBinary(at: url) {
            return .machO
        }
        
 // 5. 检查脚本（shebang + 可执行位）
        if await isExecutableScript(at: url) {
            return .script
        }
        
        return .file
    }
    
 /// 判断是否需要检查公证
 /// 只有可执行文件（app, pkg, dmg, Mach-O, 可执行脚本）需要检查
    func shouldCheckNotarization(at url: URL) async -> Bool {
        let targetType = await detectTargetType(at: url)
        
        switch targetType {
        case .bundle, .machO:
            return true
        case .script:
 // 脚本需要有可执行权限才检查
            return await hasExecutablePermission(at: url)
        case .file, .archive, .directory:
            return false
        }
    }
    
 // MARK: - Private Methods
    
 /// 解析 spctl 公证验证结果
    private func parseNotarizationResult(from result: ProcessResult) -> NotarizationResult {
        let output = result.stderr + result.stdout
        
 // 检查是否已公证
 // 典型输出: "source=Notarized Developer ID" 或 "source=Apple System"
        if output.contains("Notarized") || output.contains("Apple System") {
            let source = extractSource(from: output)
            logger.info("✅ 文件已公证: \(source ?? "Unknown")")
            return NotarizationResult.notarized(source: source)
        }
        
 // 检查是否被拒绝
        if result.exitCode != 0 || output.contains("rejected") || output.contains("a sealed resource is missing or invalid") {
            logger.warning("⚠️ 文件未公证或被拒绝")
            return NotarizationResult.notNotarized(error: output)
        }
        
 // 检查是否为开发者签名但未公证
        if output.contains("Developer ID") && !output.contains("Notarized") {
            logger.info("📋 文件有开发者签名但未公证")
            return NotarizationResult.notNotarized(error: "Signed but not notarized")
        }
        
 // 无法确定
        return NotarizationResult.unknown(error: "Unable to determine notarization status")
    }
    
 /// 解析 Gatekeeper 评估结果
    private func parseGatekeeperResult(from result: ProcessResult) -> GatekeeperResult {
        let output = result.stderr + result.stdout
        
 // 检查是否允许
        if result.exitCode == 0 || output.contains("accepted") {
            let source = extractSource(from: output)
            logger.info("✅ Gatekeeper 允许: \(source ?? "Unknown")")
            return GatekeeperResult.allow(source: source)
        }
        
 // 检查是否拒绝
        if output.contains("rejected") || output.contains("denied") {
            logger.warning("⚠️ Gatekeeper 拒绝")
            return GatekeeperResult.deny(error: output)
        }
        
 // 无法确定
        return GatekeeperResult.unknown(error: "Unable to determine Gatekeeper assessment")
    }
    
 /// 从输出中提取 source 信息
    private func extractSource(from output: String) -> String? {
 // 查找 "source=" 模式
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.contains("source=") {
                if let range = line.range(of: "source=") {
                    return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
    
 /// 检查文件是否为 Mach-O 二进制
    private func isMachOBinary(at url: URL) async -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        
        let headerData = handle.readData(ofLength: 4)
        guard headerData.count >= 4 else { return false }
        
        let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self) }
        
 // Mach-O 魔数
        let machOMagics: Set<UInt32> = [
            0xFEEDFACE, 0xCEFAEDFE,  // 32-bit
            0xFEEDFACF, 0xCFFAEDFE,  // 64-bit
            0xCAFEBABE, 0xBEBAFECA,  // FAT
            0xCAFEBABF, 0xBFBAFECA   // FAT 64-bit
        ]
        
        return machOMagics.contains(magic)
    }
    
 /// 检查文件是否为可执行脚本
    private func isExecutableScript(at url: URL) async -> Bool {
 // 检查 shebang
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        
        let headerData = handle.readData(ofLength: 2)
        guard headerData.count >= 2 else { return false }
        
 // #! = 0x23 0x21
        let hasShebang = headerData[0] == 0x23 && headerData[1] == 0x21
        
        if !hasShebang {
            return false
        }
        
 // 检查可执行权限
        return await hasExecutablePermission(at: url)
    }
    
 /// 检查文件是否有可执行权限
    private func hasExecutablePermission(at url: URL) async -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attrs[.posixPermissions] as? Int else {
            return false
        }
        
 // 检查任意执行位
        return (permissions & 0o111) != 0
    }
}
#endif
