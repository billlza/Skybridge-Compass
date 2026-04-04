import Foundation
import Darwin
import SkyBridgeCore

@MainActor
private final class LocalLanInteropHostCoordinator {
    private let discoveryManager = DeviceDiscoveryManager()
    private let fileTransferManager = FileTransferManager.shared
    private let remoteControlManager = RemoteControlManager()
    private lazy var reporter = SmokeStatusReporter(statusURL: self.statusURL())
    private var monitorTask: Task<Void, Never>?

    private lazy var fileTransferListener = FileTransferListenerService(manager: fileTransferManager)
    private lazy var remoteControlServer = RemoteControlServer(manager: remoteControlManager)

    func start() async throws {
        reporter.reset()
        reporter.append("boot role=mac-host")
        guard await discoveryManager.waitUntilInitialized(timeout: 5.0) else {
            throw HostStartupError.initializationTimedOut("DeviceDiscoveryManager")
        }
        guard await fileTransferManager.waitUntilInitialized(timeout: 5.0) else {
            throw HostStartupError.initializationTimedOut("FileTransferManager")
        }

        let inboundDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/SkyBridgeInteropInbox", isDirectory: true)
        fileTransferManager.setReceiveBaseDirectory(inboundDirectory)

        try await fileTransferManager.start()
        try await discoveryManager.start()
        try await fileTransferListener.start()
        try await remoteControlServer.start()
        try await exportLocalPQCIdentityIfRequested(reporter: reporter)

        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.SkyBridge.Compass/settings.json")

        emit("LocalLanInteropHost ready.")
        emit("Discovery/control: _skybridge._tcp on 9527")
        emit("File transfer: \(fileTransferListener.activePort ?? 8080)")
        emit("Remote desktop: \(remoteControlServer.activePort ?? 5901)")
        emit("Inbound files: \(inboundDirectory.path)")
        emit("Settings reference: \(settingsPath.path)")
        emit("Keep this process running while Azure relay and Windows client are active.")

        reporter.append("ready discovery=_skybridge._tcp port=9527")
        monitorPresence()
    }

    private func emit(_ line: String) {
        let data = Data((line + "\n").utf8)
        FileHandle.standardOutput.write(data)
    }

    private func monitorPresence() {
        monitorTask?.cancel()
        let expectsPQCRekey = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY"] == "1"

        monitorTask = Task { @MainActor in
            var lastSuite = ""
            var lastRekey = ""
            var sawClassicHandshake = false
            var sawRekey = false
            var xwingStableSince: Date?

            while !Task.isCancelled {
                let newestConnection = ConnectionPresenceService.shared.activeConnections
                    .sorted { $0.connectedAt > $1.connectedAt }
                    .first

                if let newestConnection {
                    let suite = newestConnection.suite.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !suite.isEmpty, suite != lastSuite {
                        lastSuite = suite
                        reporter.append(
                            "suite peer=\(sanitize(newestConnection.id)) suite=\(sanitize(suite))"
                        )

                        let normalizedSuite = suite.uppercased()
                        if normalizedSuite.contains("X25519") {
                            sawClassicHandshake = true
                            xwingStableSince = nil
                        } else if normalizedSuite == "X-WING" {
                            xwingStableSince = xwingStableSince ?? Date()
                        } else {
                            xwingStableSince = nil
                        }
                    }
                }

                let newestRekey = ConnectionPresenceService.shared.rekeyStatusByPeerId.values
                    .sorted { $0.startedAt > $1.startedAt }
                    .first
                if let newestRekey {
                    let description = "\(newestRekey.fromSuite)->\(newestRekey.toSuite)"
                    if description != lastRekey {
                        lastRekey = description
                        sawRekey = true
                        reporter.append(
                            "rekey \(sanitize(newestRekey.fromSuite)) -> \(sanitize(newestRekey.toSuite))"
                        )
                    }
                } else if !lastRekey.isEmpty {
                    lastRekey = ""
                    reporter.append("rekey cleared")
                }

                if let newestConnection {
                    let normalizedSuite = newestConnection.suite.uppercased()
                    if expectsPQCRekey {
                        if sawClassicHandshake && sawRekey && normalizedSuite == "X-WING" {
                            reporter.append(
                                "success peer=\(sanitize(newestConnection.id)) suite=X-Wing bootstrapRekey=1"
                            )
                            return
                        }
                    } else if normalizedSuite == "X-WING",
                              !sawRekey,
                              let stableSince = xwingStableSince,
                              Date().timeIntervalSince(stableSince) >= 1.0 {
                        reporter.append(
                            "success peer=\(sanitize(newestConnection.id)) suite=X-Wing handshakeOnly=1"
                        )
                        return
                    }
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func exportLocalPQCIdentityIfRequested(
        reporter: SmokeStatusReporter
    ) async throws {
        guard let reportURL = pqcReportURL() else { return }

        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        let deviceId = await DeviceIdentityKeyManager.shared.getDeviceId()
        let keys = try await DeviceIdentityKeyManager.shared.pairingIdentityKEMPublicKeys(
            using: provider
        )
        let report = LocalPQCReport(
            deviceId: deviceId,
            keys: keys.map { key in
                LocalPQCReport.PublicKeyEntry(
                    suiteWireId: key.suiteWireId,
                    publicKeyBase64: key.publicKey.base64EncodedString()
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try writeProtectedData(data, to: reportURL)
        reporter.append(
            "pqc-report device=\(sanitize(deviceId)) keys=\(report.keys.count) file=\(sanitize(reportURL.lastPathComponent))"
        )
    }

    private func statusURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private func pqcReportURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_PQC_REPORT_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}

private enum HostStartupError: LocalizedError {
    case initializationTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .initializationTimedOut(let component):
            return "\(component) did not finish initialization before the host timeout."
        }
    }
}

@main
struct LocalLanInteropHostMain {
    static func main() async {
        setenv("SKYBRIDGE_SMOKE_ROLE", "mac-host", 1)
        let coordinator = await MainActor.run { LocalLanInteropHostCoordinator() }

        do {
            try await coordinator.start()
        } catch {
            fputs("LocalLanInteropHost failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }

        while true {
            try? await Task.sleep(nanoseconds: 86_400_000_000_000)
        }
    }
}

private struct LocalPQCReport: Encodable {
    struct PublicKeyEntry: Encodable {
        let suiteWireId: UInt16
        let publicKeyBase64: String
    }

    let deviceId: String
    let keys: [PublicKeyEntry]
}

private struct SmokeStatusReporter {
    let statusURL: URL?

    func reset() {
        guard let statusURL else { return }
        try? writeProtectedData(Data(), to: statusURL)
    }

    func append(_ line: String) {
        guard let statusURL else { return }
        let formatted = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let data = formatted.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: statusURL.path),
           let handle = try? FileHandle(forWritingTo: statusURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? writeProtectedData(data, to: statusURL)
        }
    }
}

private func writeProtectedData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: url.path) {
        try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
    } else {
        FileManager.default.createFile(atPath: url.path, contents: data)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}
