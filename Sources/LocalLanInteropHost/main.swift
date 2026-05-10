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

    private var expectsFileTransferSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_FILE_TRANSFER"] == "1"
    }

    private var expectedHandshakeSuite: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "X-Wing"
    }

    private var fileTransferRunID: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "default"
    }

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
            var inferredRekeyLogged = false
            var suiteStableSince: Date?
            let expectedNormalizedSuite = expectedHandshakeSuite.uppercased()

            while !Task.isCancelled {
                let newestConnection = ConnectionPresenceService.shared.activeConnections
                    .sorted { $0.connectedAt > $1.connectedAt }
                    .first

                if let newestConnection {
                    let suite = newestConnection.suite.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !suite.isEmpty, suite != lastSuite {
                        lastSuite = suite
                        suiteStableSince = Date()
                        reporter.append(
                            "suite peer=\(sanitize(newestConnection.id)) suite=\(sanitize(suite))"
                        )

                        let normalizedSuite = suite.uppercased()
                        if normalizedSuite.contains("X25519") {
                            sawClassicHandshake = true
                        } else if normalizedSuite == "X-WING" {
                            if expectsPQCRekey && sawClassicHandshake && !sawRekey && !inferredRekeyLogged {
                                sawRekey = true
                                inferredRekeyLogged = true
                                reporter.append("rekey inferred X25519-Ed25519 -> X-Wing")
                            }
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
                            if expectsFileTransferSmoke {
                                do {
                                    try await performBidirectionalFileTransferSmoke(reporter: reporter)
                                    reporter.append(
                                        "success peer=\(sanitize(newestConnection.id)) suite=X-Wing bootstrapRekey=1 fileTransfer=1"
                                    )
                                } catch {
                                    reporter.append("failed stage=file-transfer error=\(sanitize(error.localizedDescription))")
                                }
                            } else {
                                reporter.append(
                                    "success peer=\(sanitize(newestConnection.id)) suite=X-Wing bootstrapRekey=1"
                                )
                            }
                            return
                        }
                    } else if normalizedSuite == expectedNormalizedSuite,
                              !sawRekey,
                              let stableSince = suiteStableSince,
                              Date().timeIntervalSince(stableSince) >= 1.0 {
                        if expectsFileTransferSmoke {
                            do {
                                try await performBidirectionalFileTransferSmoke(reporter: reporter)
                                reporter.append(
                                    "success peer=\(sanitize(newestConnection.id)) suite=\(sanitize(newestConnection.suite)) handshakeOnly=1 fileTransfer=1"
                                )
                            } catch {
                                reporter.append("failed stage=file-transfer error=\(sanitize(error.localizedDescription))")
                            }
                        } else {
                            reporter.append(
                                "success peer=\(sanitize(newestConnection.id)) suite=\(sanitize(newestConnection.suite)) handshakeOnly=1"
                            )
                        }
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

    private func performBidirectionalFileTransferSmoke(
        reporter: SmokeStatusReporter
    ) async throws {
        let inboundName = "ios-smoke-\(fileTransferRunID).txt"
        let outboundName = "mac-smoke-\(fileTransferRunID).txt"

        let inboundTransfer = try await waitForCompletedTransfer(
            fileName: inboundName,
            direction: .incoming,
            timeoutSeconds: 90
        )
        guard let inboundPath = inboundTransfer.localPath?.path,
              FileManager.default.fileExists(atPath: inboundPath) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 2001,
                userInfo: [NSLocalizedDescriptionKey: "mac smoke 未找到接收到的文件 \(inboundName)"]
            )
        }
        reporter.append("file-transfer inbound-complete name=\(sanitize(inboundName))")

        let outboundURL = try makeSmokeTransferFile(
            fileName: outboundName,
            contents: """
            role=mac
            run=\(fileTransferRunID)
            sentAt=\(ISO8601DateFormatter().string(from: Date()))
            """
        )
        reporter.append("file-transfer outbound-start name=\(sanitize(outboundName))")
        let targetDeviceId = Self.stableBonjourTargetDeviceId(inboundTransfer.deviceId)
        guard let route = await BonjourFileTransferRouteResolver().resolve(
            targetDeviceId: targetDeviceId,
            preferredName: inboundTransfer.deviceName,
            timeoutSeconds: 6.0
        ) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 2002,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "未发现匹配 \(inboundTransfer.deviceId) 的 _skybridge-transfer._tcp Bonjour 路由"
                ]
            )
        }
        reporter.append(
            "file-transfer outbound-route source=bonjour-transfer device=\(sanitize(route.deviceId ?? inboundTransfer.deviceId)) host=\(sanitize(route.host)) port=\(route.port)"
        )
        try await fileTransferManager.sendFile(
            at: outboundURL,
            to: inboundTransfer.deviceId,
            deviceName: route.name,
            ipAddress: route.host,
            port: route.port
        )
        reporter.append("file-transfer outbound-complete name=\(sanitize(outboundName))")
    }

    private static func stableBonjourTargetDeviceId(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        guard !lowered.hasPrefix("peer:"),
              !lowered.hasPrefix("host:"),
              !lowered.hasPrefix("bonjour:") else {
            return nil
        }
        if lowered.hasPrefix("id:") {
            return String(trimmed.dropFirst("id:".count))
        }
        return trimmed
    }

    private func makeSmokeTransferFile(fileName: String, contents: String) throws -> URL {
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SkyBridgeSmokeTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory.appendingPathComponent(fileName, isDirectory: false)
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    private func waitForCompletedTransfer(
        fileName: String,
        direction: TransferDirection,
        timeoutSeconds: TimeInterval
    ) async throws -> FileTransfer {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let transfer = fileTransferManager.transferHistory.first(where: { transfer in
                transfer.fileName == fileName
                    && transfer.status == .completed
                    && transfer.direction == direction
            }) {
                return transfer
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        throw NSError(
            domain: "SkyBridge.Smoke",
            code: 2000,
            userInfo: [NSLocalizedDescriptionKey: "等待传输完成超时: \(fileName)"]
        )
    }
}

private struct BonjourFileTransferRoute {
    let name: String
    let host: String
    let port: Int
    let deviceId: String?
    let platform: String?
}

@MainActor
private final class BonjourFileTransferRouteResolver: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let serviceType = "_skybridge-transfer._tcp."
    private let serviceDomain = "local."
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var candidates: [BonjourFileTransferRoute] = []
    private var continuation: CheckedContinuation<BonjourFileTransferRoute?, Never>?
    private var targetDeviceId: String?
    private var preferredName: String?
    private var finished = false

    func resolve(
        targetDeviceId: String?,
        preferredName: String?,
        timeoutSeconds: TimeInterval
    ) async -> BonjourFileTransferRoute? {
        self.targetDeviceId = Self.normalizedDeviceId(targetDeviceId)
        self.preferredName = preferredName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let browser = NetServiceBrowser()
            self.browser = browser
            browser.delegate = self
            browser.searchForServices(ofType: serviceType, inDomain: serviceDomain)

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0.5, timeoutSeconds)))
                guard let self else { return }
                self.finish(with: self.bestCandidate())
            }
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        services.append(service)
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 2.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let route = makeRoute(from: sender) else { return }
        candidates.append(route)

        if let targetDeviceId,
           let candidateDeviceId = Self.normalizedDeviceId(route.deviceId),
           candidateDeviceId == targetDeviceId {
            finish(with: route)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        sender.stop()
    }

    private func makeRoute(from service: NetService) -> BonjourFileTransferRoute? {
        let txt = service.txtRecordData().map(Self.parseTXTRecord(_:)) ?? [:]
        let advertisedPort = Self.intValue(
            txt["fileTransferPort"] ?? txt["transferPort"] ?? txt["file_transfer_port"] ?? txt["port"]
        )
        let port = service.port > 0 ? service.port : advertisedPort
        guard (1...65535).contains(port) else { return nil }

        let host = service.hostName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? Self.firstUsableAddress(from: service.addresses)
        guard let host, !host.isEmpty else { return nil }

        let deviceId = txt["deviceId"] ?? txt["id"] ?? txt["deviceID"] ?? txt["device_id"]
        let name = txt["name"] ?? txt["device"] ?? service.name
        let platform = txt["platform"] ?? txt["os"]
        return BonjourFileTransferRoute(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? service.name,
            host: host,
            port: port,
            deviceId: deviceId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            platform: platform?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private func bestCandidate() -> BonjourFileTransferRoute? {
        if let targetDeviceId {
            return candidates.first { candidate in
                Self.normalizedDeviceId(candidate.deviceId) == targetDeviceId
            }
        }

        if let preferredName {
            let named = candidates.filter { route in
                route.name.lowercased().contains(preferredName)
            }
            if named.count == 1 {
                return named.first
            }
        }

        let iOSCandidates = candidates.filter { route in
            route.platform?.lowercased().contains("ios") == true
                || route.name.lowercased().contains("ipad")
                || route.name.lowercased().contains("iphone")
        }
        if iOSCandidates.count == 1 {
            return iOSCandidates.first
        }

        return candidates.count == 1 ? candidates.first : nil
    }

    private func finish(with route: BonjourFileTransferRoute?) {
        guard !finished else { return }
        finished = true
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        for service in services {
            service.stop()
            service.delegate = nil
            service.remove(from: .main, forMode: .common)
        }
        services.removeAll()
        continuation?.resume(returning: route)
        continuation = nil
    }

    private static func parseTXTRecord(_ data: Data) -> [String: String] {
        NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) { result, pair in
            guard let value = String(data: pair.value, encoding: .utf8) else { return }
            result[pair.key] = value
        }
    }

    private static func normalizedDeviceId(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("id:") {
            value.removeFirst("id:".count)
        }
        return value
    }

    private static func intValue(_ raw: String?) -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return 0 }
        return Int(raw) ?? 0
    }

    private static func firstUsableAddress(from addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        var linkLocalIPv6: String?
        for data in addresses {
            let address = extractAddress(from: data)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, address != "未知地址" else { continue }
            let lower = address.lowercased()
            if lower.contains("."),
               !lower.hasPrefix("127."),
               !lower.hasPrefix("169.254") {
                return address
            }
            if lower.hasPrefix("fe80:"), lower.contains("%"), linkLocalIPv6 == nil {
                linkLocalIPv6 = address
            } else if lower.contains(":"),
                      !lower.hasPrefix("fe80:") {
                return address
            }
        }
        return linkLocalIPv6
    }

    private static func extractAddress(from data: Data) -> String {
        data.withUnsafeBytes { bytes in
            guard bytes.count >= MemoryLayout<sockaddr>.size,
                  let sockaddr = bytes.bindMemory(to: sockaddr.self).baseAddress else {
                return ""
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(sockaddr.pointee.sa_len)
            let flags = NI_NUMERICHOST
            guard getnameinfo(sockaddr, length, &host, socklen_t(host.count), nil, 0, flags) == 0 else {
                return ""
            }
            let data = Data(bytes: host, count: host.count)
            let trimmed = data.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self)
        }
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
        let enableCompatibilityBootstrap =
            ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ENABLE_COMPATIBILITY_MODE"] == "1"
            || ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY"] == "1"
        if enableCompatibilityBootstrap {
            var smokeDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            smokeDefaults["Settings.EnableCompatibilityMode"] = true
            UserDefaults.standard.setVolatileDomain(smokeDefaults, forName: UserDefaults.argumentDomain)
        }
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
