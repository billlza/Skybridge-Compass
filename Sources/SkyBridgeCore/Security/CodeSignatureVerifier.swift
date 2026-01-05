//
// CodeSignatureVerifier.swift
// SkyBridgeCore
//
// 代码签名验证模块
// 优先使用 Security.framework API，回退到 codesign CLI
//

import Foundation
import Security
import OSLog

// MARK: - ProcessResult

/// 进程执行结果
internal struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

// MARK: - ProcessRunning Protocol

/// 进程执行器协议 - 便于测试注入
internal protocol ProcessRunning: Sendable {
    func run(command: String, arguments: [String]) async throws -> ProcessResult
}

// MARK: - DefaultProcessRunner

/// 默认进程执行器实现
internal struct DefaultProcessRunner: ProcessRunning {
    func run(command: String, arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        try process.run()
        process.waitUntilExit()
        
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

// MARK: - CodeSignatureResult

/// 代码签名验证结果
internal struct CodeSignatureResult: Sendable {
    let isValid: Bool
    let signerIdentity: String?
    let teamIdentifier: String?
    let isAdHoc: Bool
    let error: String?
    
    static func unsigned() -> CodeSignatureResult {
        CodeSignatureResult(
            isValid: false,
            signerIdentity: nil,
            teamIdentifier: nil,
            isAdHoc: false,
            error: "Code is not signed"
        )
    }
    
    static func invalid(error: String) -> CodeSignatureResult {
        CodeSignatureResult(
            isValid: false,
            signerIdentity: nil,
            teamIdentifier: nil,
            isAdHoc: false,
            error: error
        )
    }
}

// MARK: - CodeSignatureVerifying Protocol

/// 代码签名验证协议 - 便于后续切换实现
internal protocol CodeSignatureVerifying: Sendable {
    func verify(at url: URL) async -> CodeSignatureResult
    func isMachOBinary(at url: URL) async -> Bool
}

// MARK: - CodeSignatureVerifier Actor

/// 代码签名验证器
/// 优先使用 Security.framework 的 SecStaticCode/SecCodeCopySigningInformation
/// 回退到 codesign CLI（封装为可替换实现）
internal actor CodeSignatureVerifier: CodeSignatureVerifying {
    
    private let logger = Logger(subsystem: "com.skybridge.security", category: "CodeSignature")
    
 /// 可注入的进程执行器（便于测试）
    private let processRunner: ProcessRunning
    
 /// 是否使用 CLI 回退（当 Security.framework 失败时）
    private let useCLIFallback: Bool
    
    init(processRunner: ProcessRunning = DefaultProcessRunner(), useCLIFallback: Bool = true) {
        self.processRunner = processRunner
        self.useCLIFallback = useCLIFallback
    }

    
 // MARK: - Public API
    
 /// 验证文件的代码签名
 /// - Parameter url: 文件 URL
 /// - Returns: 签名验证结果
    func verify(at url: URL) async -> CodeSignatureResult {
        logger.debug("🔐 验证代码签名: \(url.lastPathComponent)")
        
 // 优先使用 Security.framework API
        let frameworkResult = await verifyWithSecurityFramework(at: url)
        
 // 如果 Security.framework 成功或明确失败，直接返回
        if frameworkResult.isValid || !useCLIFallback {
            return frameworkResult
        }
        
 // 回退到 codesign CLI
        logger.debug("📋 回退到 codesign CLI 验证")
        return await verifyWithCodesignCLI(at: url)
    }
    
 /// 检查文件是否为 Mach-O 二进制
 /// 使用魔数判断：0xFEEDFACE (32-bit), 0xFEEDFACF (64-bit), FAT binary
 /// - Parameter url: 文件 URL
 /// - Returns: 是否为 Mach-O 二进制
    func isMachOBinary(at url: URL) async -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        
        let headerData = handle.readData(ofLength: 4)
        guard headerData.count >= 4 else { return false }
        
        let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self) }
        
 // Mach-O 魔数（支持大小端）
 // MH_MAGIC = 0xFEEDFACE (32-bit, little-endian)
 // MH_CIGAM = 0xCEFAEDFE (32-bit, big-endian)
 // MH_MAGIC_64 = 0xFEEDFACF (64-bit, little-endian)
 // MH_CIGAM_64 = 0xCFFAEDFE (64-bit, big-endian)
 // FAT_MAGIC = 0xCAFEBABE (universal, big-endian)
 // FAT_CIGAM = 0xBEBAFECA (universal, little-endian)
 // FAT_MAGIC_64 = 0xCAFEBABF (universal 64-bit, big-endian)
 // FAT_CIGAM_64 = 0xBFBAFECA (universal 64-bit, little-endian)
        
        let machOMagics: Set<UInt32> = [
            0xFEEDFACE, 0xCEFAEDFE,  // 32-bit
            0xFEEDFACF, 0xCFFAEDFE,  // 64-bit
            0xCAFEBABE, 0xBEBAFECA,  // FAT
            0xCAFEBABF, 0xBFBAFECA   // FAT 64-bit
        ]
        
        return machOMagics.contains(magic)
    }
    
 // MARK: - Security.framework Implementation
    
 /// 使用 Security.framework 验证代码签名
    private func verifyWithSecurityFramework(at url: URL) async -> CodeSignatureResult {
        var staticCode: SecStaticCode?
        
 // 创建 SecStaticCode 对象
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            let errorMsg = securityErrorMessage(for: createStatus)
            logger.warning("⚠️ 无法创建 SecStaticCode: \(errorMsg)")
            return CodeSignatureResult.invalid(error: errorMsg)
        }
        
 // 验证签名有效性
        let validateStatus = SecStaticCodeCheckValidity(code, [], nil)
        
        if validateStatus == errSecCSUnsigned {
            logger.info("📋 文件未签名: \(url.lastPathComponent)")
            return CodeSignatureResult.unsigned()
        }
        
        if validateStatus != errSecSuccess {
            let errorMsg = securityErrorMessage(for: validateStatus)
            logger.warning("⚠️ 签名验证失败: \(errorMsg)")
            return CodeSignatureResult.invalid(error: errorMsg)
        }
        
 // 获取签名信息
        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        
        guard infoStatus == errSecSuccess, let info = signingInfo as? [String: Any] else {
            return CodeSignatureResult(
                isValid: true,
                signerIdentity: nil,
                teamIdentifier: nil,
                isAdHoc: false,
                error: nil
            )
        }
        
 // 解析签名信息
        let signerIdentity = extractSignerIdentity(from: info)
        let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
        let isAdHoc = checkIsAdHoc(from: info)
        
        logger.info("✅ 签名验证成功: \(signerIdentity ?? "Unknown")")
        
        return CodeSignatureResult(
            isValid: true,
            signerIdentity: signerIdentity,
            teamIdentifier: teamIdentifier,
            isAdHoc: isAdHoc,
            error: nil
        )
    }

    
 // MARK: - codesign CLI Fallback
    
 /// 使用 codesign CLI 验证代码签名（回退方案）
    private func verifyWithCodesignCLI(at url: URL) async -> CodeSignatureResult {
        do {
 // 执行 codesign -dv --verbose=4
            let result = try await processRunner.run(
                command: "/usr/bin/codesign",
                arguments: ["-dv", "--verbose=4", url.path]
            )
            
 // codesign 输出到 stderr（正常行为）
            let output = result.stderr
            
 // 检查是否未签名
            if output.contains("code object is not signed at all") {
                return CodeSignatureResult.unsigned()
            }
            
 // 检查签名是否有效
            if result.exitCode != 0 {
                return CodeSignatureResult.invalid(error: "codesign verification failed: \(output)")
            }
            
 // 解析签名信息
            let signerIdentity = parseSignerIdentity(from: output)
            let teamIdentifier = parseTeamIdentifier(from: output)
            let isAdHoc = output.contains("Signature=adhoc")
            
            return CodeSignatureResult(
                isValid: true,
                signerIdentity: signerIdentity,
                teamIdentifier: teamIdentifier,
                isAdHoc: isAdHoc,
                error: nil
            )
            
        } catch {
            logger.error("❌ codesign CLI 执行失败: \(error.localizedDescription)")
            return CodeSignatureResult.invalid(error: error.localizedDescription)
        }
    }
    
 // MARK: - Helper Methods
    
 /// 从签名信息中提取签名者身份
    private func extractSignerIdentity(from info: [String: Any]) -> String? {
 // 尝试从证书链中获取
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let firstCert = certificates.first {
            var commonName: CFString?
            if SecCertificateCopyCommonName(firstCert, &commonName) == errSecSuccess {
                return commonName as String?
            }
        }
        
 // 尝试从 identifier 获取
        if let identifier = info[kSecCodeInfoIdentifier as String] as? String {
            return identifier
        }
        
        return nil
    }
    
 /// 检查是否为 ad-hoc 签名
    private func checkIsAdHoc(from info: [String: Any]) -> Bool {
 // ad-hoc 签名没有证书链
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
            return certificates.isEmpty
        }
        
 // 检查 flags
        if let flags = info[kSecCodeInfoFlags as String] as? UInt32 {
 // kSecCodeSignatureAdhoc = 0x0002
            return (flags & 0x0002) != 0
        }
        
        return false
    }
    
 /// 从 codesign 输出解析签名者身份
    private func parseSignerIdentity(from output: String) -> String? {
 // 查找 "Authority=" 行
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("Authority=") {
                return String(line.dropFirst("Authority=".count))
            }
        }
        
 // 查找 "Identifier=" 行
        for line in lines {
            if line.hasPrefix("Identifier=") {
                return String(line.dropFirst("Identifier=".count))
            }
        }
        
        return nil
    }
    
 /// 从 codesign 输出解析 Team Identifier
    private func parseTeamIdentifier(from output: String) -> String? {
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("TeamIdentifier=") {
                let value = String(line.dropFirst("TeamIdentifier=".count))
 // "not set" 表示没有 team identifier
                return value == "not set" ? nil : value
            }
        }
        return nil
    }
    
 /// 获取 Security 框架错误消息
    private func securityErrorMessage(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) {
            return message as String
        }
        return "Unknown error (code: \(status))"
    }
}

// MARK: - CodeSignatureInfo Extension

extension CodeSignatureInfo {
 /// 从 CodeSignatureResult 创建 CodeSignatureInfo
    init(from result: CodeSignatureResult) {
        let trustLevel: TrustLevel
        
        if !result.isValid {
            if result.error?.contains("not signed") == true {
                trustLevel = .unsigned
            } else {
                trustLevel = .invalid
            }
        } else if result.isAdHoc {
            trustLevel = .adHoc
        } else if result.teamIdentifier != nil {
            trustLevel = .identified
        } else if result.signerIdentity?.contains("Apple") == true {
            trustLevel = .trusted
        } else {
            trustLevel = .identified
        }
        
        self.init(
            isSigned: result.isValid || result.isAdHoc,
            isValid: result.isValid,
            signerIdentity: result.signerIdentity,
            teamIdentifier: result.teamIdentifier,
            isAdHoc: result.isAdHoc,
            trustLevel: trustLevel
        )
    }
}
