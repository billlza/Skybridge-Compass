import Foundation
import CryptoKit
import NIOCore
import NIOSSH
import OSLog

public struct SSHKnownHostEntry: Codable, Equatable, Identifiable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let fingerprint: String

    public var id: String {
        "\(host):\(port):\(keyType):\(fingerprint)"
    }
}

public struct SSHKnownHostsImportResult: Sendable {
    public let added: Int
    public let skipped: Int
}

/// SSH known-hosts store with fingerprint validation.
public final class SSHKnownHostsStore: @unchecked Sendable {
    public static let shared = SSHKnownHostsStore()

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SSHKnownHosts")
    private let storageKey = "ssh.knownHosts"
    private let queue = DispatchQueue(label: "com.skybridge.ssh.knownhosts")
    private let defaults = UserDefaults(suiteName: "com.skybridge.compass") ?? .standard
    private var entries: [SSHKnownHostEntry] = []

    private init() {
        load()
    }

    func isTrusted(host: String, port: Int, keyType: String, fingerprint: String) -> Bool {
        queue.sync {
            entries.contains { $0.host == host && $0.port == port && $0.keyType == keyType && $0.fingerprint == fingerprint }
        }
    }

    @discardableResult
    func record(host: String, port: Int, keyType: String, fingerprint: String) -> Bool {
        queue.sync {
            let entry = SSHKnownHostEntry(host: host, port: port, keyType: keyType, fingerprint: fingerprint)
            if entries.contains(entry) {
                return false
            }
            entries.append(entry)
            saveLocked()
            return true
        }
    }

    func fingerprint(for hostKey: NIOSSHPublicKey) -> (keyType: String, fingerprint: String)? {
        let openSSH = String(openSSHPublicKey: hostKey)
        let parts = openSSH.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            logger.error("无法解析 OpenSSH 公钥格式")
            return nil
        }
        let keyType = String(parts[0])
        guard let keyData = Data(base64Encoded: String(parts[1])) else {
            logger.error("无法解析 OpenSSH 公钥 Base64 数据")
            return nil
        }
        let digest = SHA256.hash(data: keyData)
        let fingerprint = digest.compactMap { String(format: "%02x", $0) }.joined()
        return (keyType: keyType, fingerprint: fingerprint)
    }

    func fingerprintForOpenSSHKey(keyType: String, keyData: String) -> (keyType: String, fingerprint: String)? {
        let openSSH = "\(keyType) \(keyData)"
        guard let publicKey = try? NIOSSHPublicKey(openSSHPublicKey: openSSH) else {
            return nil
        }
        return fingerprint(for: publicKey)
    }

    public func allEntries() -> [SSHKnownHostEntry] {
        queue.sync {
            entries.sorted {
                if $0.host == $1.host {
                    if $0.port == $1.port {
                        return $0.keyType < $1.keyType
                    }
                    return $0.port < $1.port
                }
                return $0.host < $1.host
            }
        }
    }

    public func removeAll() {
        queue.sync {
            entries.removeAll()
            saveLocked()
        }
    }

    public func remove(entry: SSHKnownHostEntry) {
        queue.sync {
            entries.removeAll { $0 == entry }
            saveLocked()
        }
    }

    @discardableResult
    public func addOpenSSHPublicKey(host: String, port: Int, openSSHPublicKey: String) throws -> Bool {
        let parts = openSSHPublicKey.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw SSHHostKeyValidationError.invalidHostKey
        }
        let keyType = String(parts[0])
        let keyData = String(parts[1])
        guard let info = fingerprintForOpenSSHKey(keyType: keyType, keyData: keyData) else {
            throw SSHHostKeyValidationError.invalidHostKey
        }
        return record(host: host, port: port, keyType: info.keyType, fingerprint: info.fingerprint)
    }

    public func importKnownHostsFile(from url: URL) throws -> SSHKnownHostsImportResult {
        let content = try String(contentsOf: url, encoding: .utf8)
        var added = 0
        var skipped = 0

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3 else {
                skipped += 1
                continue
            }
            let hostField = String(fields[0])
            if hostField.hasPrefix("|") {
                skipped += 1
                continue
            }
            let keyType = String(fields[1])
            let keyData = String(fields[2])
            guard let info = fingerprintForOpenSSHKey(keyType: keyType, keyData: keyData) else {
                skipped += 1
                continue
            }
            let hosts = hostField.split(separator: ",")
            for hostEntry in hosts {
                let (host, port) = parseHostField(String(hostEntry))
                if record(host: host, port: port, keyType: info.keyType, fingerprint: info.fingerprint) {
                    added += 1
                } else {
                    skipped += 1
                }
            }
        }

        return SSHKnownHostsImportResult(added: added, skipped: skipped)
    }

    private func parseHostField(_ raw: String) -> (String, Int) {
        if raw.hasPrefix("["), let closing = raw.firstIndex(of: "]") {
            let host = String(raw[raw.index(after: raw.startIndex)..<closing])
            let portStart = raw.index(after: closing)
            if portStart < raw.endIndex, raw[portStart] == ":" {
                let portString = String(raw[raw.index(after: portStart)...])
                if let port = Int(portString) {
                    return (host, port)
                }
            }
            return (host, 22)
        }
        return (raw, 22)
    }

    private func load() {
        queue.sync {
            guard let data = defaults.data(forKey: storageKey) else {
                entries = []
                return
            }
            entries = (try? JSONDecoder().decode([SSHKnownHostEntry].self, from: data)) ?? []
        }
    }

    private func saveLocked() {
        do {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: storageKey)
        } catch {
            logger.error("保存 known-hosts 失败: \(error.localizedDescription)")
        }
    }
}

public enum SSHHostKeyValidationError: Error {
    case unknownHostKey
    case hostKeyMismatch
    case invalidHostKey
}

/// Strict host key validation delegate backed by SSHKnownHostsStore.
final class SSHKnownHostsDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: Int
    private let trustOnFirstUse: Bool
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SSHKnownHostsDelegate")

    init(host: String, port: Int, trustOnFirstUse: Bool) {
        self.host = host
        self.port = port
        self.trustOnFirstUse = trustOnFirstUse
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let info = SSHKnownHostsStore.shared.fingerprint(for: hostKey) else {
            validationCompletePromise.fail(SSHHostKeyValidationError.invalidHostKey)
            return
        }

        if SSHKnownHostsStore.shared.isTrusted(host: host, port: port, keyType: info.keyType, fingerprint: info.fingerprint) {
            validationCompletePromise.succeed(())
            return
        }

        if trustOnFirstUse {
            SSHKnownHostsStore.shared.record(host: host, port: port, keyType: info.keyType, fingerprint: info.fingerprint)
            logger.warning("首次信任主机密钥（TOFU）：\(self.host):\(self.port) \(info.keyType) \(info.fingerprint)")
            validationCompletePromise.succeed(())
            return
        }

        logger.error("主机密钥未受信任：\(self.host):\(self.port) \(info.keyType) \(info.fingerprint)")
        validationCompletePromise.fail(SSHHostKeyValidationError.unknownHostKey)
    }
}
