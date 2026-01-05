#!/usr/bin/env swift
import Foundation
import CryptoKit

struct KnownHostEntry: Codable, Equatable {
    let host: String
    let port: Int
    let keyType: String
    let fingerprint: String
}

struct ImportResult {
    var added: Int = 0
    var skipped: Int = 0
}

let storageKey = "ssh.knownHosts"
let defaults = UserDefaults(suiteName: "com.skybridge.compass") ?? .standard

func usage() -> Never {
    let text = """
    Usage:
      register_ssh_host_key.swift --host <host> [--port <port>] --key "<keyType> <base64>"
      register_ssh_host_key.swift --known-hosts <path>

    Examples:
      register_ssh_host_key.swift --host example.com --port 22 --key "ssh-ed25519 AAAAC3..."
      register_ssh_host_key.swift --known-hosts ./known_hosts
    """
    print(text)
    exit(1)
}

func parseArgs() -> [String: String] {
    var result: [String: String] = [:]
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let arg = args[i]
        if arg == "--help" || arg == "-h" {
            usage()
        }
        guard i + 1 < args.count else {
            usage()
        }
        result[arg] = args[i + 1]
        i += 2
    }
    return result
}

func loadEntries() -> [KnownHostEntry] {
    guard let data = defaults.data(forKey: storageKey) else { return [] }
    return (try? JSONDecoder().decode([KnownHostEntry].self, from: data)) ?? []
}

func saveEntries(_ entries: [KnownHostEntry]) {
    do {
        let data = try JSONEncoder().encode(entries)
        defaults.set(data, forKey: storageKey)
    } catch {
        fputs("Failed to save known-hosts: \(error)\n", stderr)
        exit(2)
    }
}

func fingerprint(keyType: String, keyData: String) -> (keyType: String, fingerprint: String)? {
    guard let rawKey = Data(base64Encoded: keyData) else { return nil }
    let digest = SHA256.hash(data: rawKey)
    let fp = digest.compactMap { String(format: "%02x", $0) }.joined()
    return (keyType: keyType, fingerprint: fp)
}

func parseHostField(_ raw: String) -> (String, Int) {
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

@discardableResult
func addEntry(host: String, port: Int, keyType: String, keyData: String, entries: inout [KnownHostEntry]) -> Bool {
    guard let info = fingerprint(keyType: keyType, keyData: keyData) else {
        return false
    }
    let entry = KnownHostEntry(host: host, port: port, keyType: info.keyType, fingerprint: info.fingerprint)
    if entries.contains(entry) {
        return false
    }
    entries.append(entry)
    return true
}

func importKnownHosts(path: String, entries: inout [KnownHostEntry]) -> ImportResult {
    var result = ImportResult()
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("Failed to read file: \(path)\n", stderr)
        exit(2)
    }
    for rawLine in content.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { continue }
        if line.hasPrefix("#") { continue }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 3 else {
            result.skipped += 1
            continue
        }
        let hostField = String(fields[0])
        if hostField.hasPrefix("|") {
            result.skipped += 1
            continue
        }
        let keyType = String(fields[1])
        let keyData = String(fields[2])
        let hosts = hostField.split(separator: ",")
        for hostEntry in hosts {
            let (host, port) = parseHostField(String(hostEntry))
            if addEntry(host: host, port: port, keyType: keyType, keyData: keyData, entries: &entries) {
                result.added += 1
            } else {
                result.skipped += 1
            }
        }
    }
    return result
}

let args = parseArgs()

if let knownHosts = args["--known-hosts"] {
    var entries = loadEntries()
    let result = importKnownHosts(path: knownHosts, entries: &entries)
    saveEntries(entries)
    print("Import completed: added \(result.added), skipped \(result.skipped)")
    exit(0)
}

guard let host = args["--host"], let key = args["--key"] else {
    usage()
}

let port = Int(args["--port"] ?? "22") ?? 22
let parts = key.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
guard parts.count >= 2 else {
    fputs("Invalid key format. Expected \"<keyType> <base64>\".\n", stderr)
    exit(2)
}
let keyType = String(parts[0])
let keyData = String(parts[1])

var entries = loadEntries()
let added = addEntry(host: host, port: port, keyType: keyType, keyData: keyData, entries: &entries)
saveEntries(entries)
print(added ? "Added host key." : "Host key already exists.")
