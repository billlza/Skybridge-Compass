import Darwin
import Foundation
import SkyBridgeCore

@available(macOS 14.0, *)
@MainActor
@main
struct FormalMacWebRTCHost {
    private enum Stage: String {
        case configuration
        case credentialRead
        case identityPreflight
        case codeRead
        case connect
        case handshake
        case androidToMac
        case macToAndroid
        case terminalRevalidation
        case cleanup
        case identityFreeze
        case resultWrite
    }

    private struct Configuration: Sendable {
        let signalingWSSURL: URL
        let signalingHTTPSOrigin: String
        let tokenFile: URL
        let tenantID: String
        let runRef: String
        let androidToMacTransferID: String
        let macToAndroidTransferID: String
        let connectCodeFile: URL
        let resultOutput: URL
        let timeoutSeconds: Double
        let holdSeconds: Double

        static func parse(_ arguments: [String]) throws -> Configuration {
            var values: [String: String] = [:]
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                guard key.hasPrefix("--"), index + 1 < arguments.count else {
                    throw FormalMacInteropError.invalidConfiguration
                }
                guard values.updateValue(arguments[index + 1], forKey: key) == nil else {
                    throw FormalMacInteropError.invalidConfiguration
                }
                index += 2
            }
            let required = [
                "--signaling-wss-url",
                "--token-file",
                "--tenant-id",
                "--run-ref",
                "--android-to-mac-transfer-id",
                "--mac-to-android-transfer-id",
                "--connect-code-file",
                "--result-output"
            ]
            guard required.allSatisfy({ values[$0]?.isEmpty == false }),
                  values.keys.allSatisfy({ required.contains($0)
                    || $0 == "--timeout-seconds"
                    || $0 == "--hold-seconds" }) else {
                throw FormalMacInteropError.invalidConfiguration
            }
            guard let wssURL = URL(string: values["--signaling-wss-url"]!),
                  wssURL.scheme?.lowercased() == "wss",
                  wssURL.host != nil,
                  wssURL.user == nil,
                  wssURL.password == nil,
                  wssURL.query == nil,
                  wssURL.fragment == nil else {
                throw FormalMacInteropError.invalidConfiguration
            }
            var origin = URLComponents()
            origin.scheme = "https"
            origin.host = wssURL.host
            origin.port = wssURL.port
            guard let httpsOrigin = origin.url?.absoluteString else {
                throw FormalMacInteropError.invalidConfiguration
            }
            let timeout = try boundedDouble(
                values["--timeout-seconds"] ?? "120",
                range: 10...600
            )
            let hold = try boundedDouble(values["--hold-seconds"] ?? "6", range: 1...30)
            let tokenFile = try absoluteFileURL(values["--token-file"]!)
            let codeFile = try absoluteFileURL(values["--connect-code-file"]!)
            let resultOutput = try absoluteFileURL(values["--result-output"]!)
            try requireSafeOutputDestination(resultOutput)
            return Configuration(
                signalingWSSURL: wssURL,
                signalingHTTPSOrigin: httpsOrigin,
                tokenFile: tokenFile,
                tenantID: values["--tenant-id"]!,
                runRef: values["--run-ref"]!,
                androidToMacTransferID: values["--android-to-mac-transfer-id"]!,
                macToAndroidTransferID: values["--mac-to-android-transfer-id"]!,
                connectCodeFile: codeFile,
                resultOutput: resultOutput,
                timeoutSeconds: timeout,
                holdSeconds: hold
            )
        }

        private static func boundedDouble(
            _ raw: String,
            range: ClosedRange<Double>
        ) throws -> Double {
            guard let value = Double(raw), value.isFinite, range.contains(value) else {
                throw FormalMacInteropError.invalidConfiguration
            }
            return value
        }

        private static func absoluteFileURL(_ raw: String) throws -> URL {
            guard raw.hasPrefix("/"), !raw.contains("\0") else {
                throw FormalMacInteropError.invalidConfiguration
            }
            return URL(fileURLWithPath: raw).standardizedFileURL
        }

        private static func requireSafeOutputDestination(_ url: URL) throws {
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw FormalMacInteropError.invalidConfiguration
            }
            let parent = url.deletingLastPathComponent()
            let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw FormalMacInteropError.invalidConfiguration
            }
        }
    }

    private struct SelectedICE: Encodable {
        let route: String
        let localCandidateType: String
        let remoteCandidateType: String
        let `protocol`: String
    }

    private struct Transfers: Encodable {
        let androidToMac: FormalMacTransferEvidence
        let macToAndroid: FormalMacTransferEvidence
    }

    private struct IdentityState: Encodable {
        let beforeDigest: String
        let afterDigest: String
        let unchanged: Bool
    }

    private struct SuccessResult: Encodable {
        let schemaVersion = 1
        let outcome = "success"
        let runRef: String
        let sessionRef: String
        let suite: String
        let suiteWireId: String
        let selectedIce: SelectedICE
        let transfers: Transfers
        let identityState: IdentityState
        let runOwnedPayloadCleaned: Bool
    }

    private struct FailureResult: Encodable {
        let schemaVersion = 1
        let outcome = "failed"
        let runRef: String
        let stage: String
        let errorCode: String
    }

    private enum ProtectedReadError: Error {
        case notReady
        case unsafeFile
        case tooLarge
        case changedDuringRead
        case invalidUTF8
    }

    static func main() async {
        let configuration: Configuration
        do {
            configuration = try Configuration.parse(CommandLine.arguments)
        } catch {
            FileHandle.standardError.write(Data("invalid formal host configuration\n".utf8))
            exit(EXIT_FAILURE)
        }

        var stage = Stage.credentialRead
        var manager: CrossNetworkConnectionManager?
        var frozenBinding: FormalMacSessionBinding?
        var runDirectory: URL?
        var sessionQuiesced = false
        let runParent: URL
        do {
            runParent = try formalRunParentDirectory()
        } catch {
            writeFailure(configuration: configuration, stage: .configuration, error: error)
            exit(EXIT_FAILURE)
        }

        do {
            let bearerToken = try readProtectedText(
                configuration.tokenFile,
                maximumBytes: 16 * 1024,
                allowEmpty: false
            )
            try configureServerEnvironment(configuration)

            stage = .identityPreflight
            let beforeDigest = try FormalMacPersistentStateDigest.capture()
            let localIdentity = try await DeviceIdentityKeyManager.shared
                .requireExistingFormalMacIdentity()
            let preparedRunDirectory = try FormalMacInteropFileSystem.prepareRunDirectory(
                parent: runParent,
                runRef: configuration.runRef
            )
            runDirectory = preparedRunDirectory
            let capability = try FormalMacInteropCapability(
                runRef: configuration.runRef,
                androidToMacTransferID: configuration.androidToMacTransferID,
                macToAndroidTransferID: configuration.macToAndroidTransferID,
                bearerToken: bearerToken,
                tenantID: configuration.tenantID,
                runDirectory: preparedRunDirectory,
                localIdentity: localIdentity
            )
            let formalManager = CrossNetworkConnectionManager(
                formalInteropCapability: capability
            )
            manager = formalManager

            stage = .codeRead
            let deadline = ContinuousClock.now + .seconds(configuration.timeoutSeconds)
            let code = try await waitForConnectionCode(
                at: configuration.connectCodeFile,
                deadline: deadline
            )

            stage = .connect
            _ = try await formalManager.connectWithCode(code)

            stage = .handshake
            try await waitForHandshake(manager: formalManager, deadline: deadline)
            let completionBinding = try await waitForFormalSessionBinding(
                manager: formalManager,
                deadline: deadline
            )
            // From this point onward every failure must retire this exact session before
            // any run-owned payload is removed. Keeping the binding here also prevents a
            // later/replacement connection from being quiesced under this run's authority.
            frozenBinding = completionBinding

            stage = .androidToMac
            let androidToMac = try await waitForInboundEvidence(
                manager: formalManager,
                deadline: deadline
            )

            stage = .macToAndroid
            let macToAndroid = try await formalManager.sendFormalInteropPayload()

            stage = .terminalRevalidation
            let terminalBinding = try await waitForFormalSessionBinding(
                manager: formalManager,
                deadline: deadline
            )
            guard terminalBinding == completionBinding else {
                throw FormalMacInteropError.staleSession
            }
            frozenBinding = terminalBinding
            try await Task.sleep(for: .seconds(configuration.holdSeconds))
            try await waitForFormalSessionRevalidation(
                manager: formalManager,
                binding: terminalBinding,
                deadline: min(deadline, ContinuousClock.now + .seconds(3))
            )

            stage = .cleanup
            try await formalManager.retireAndQuiesceFormalInteropSession(
                requiredBinding: terminalBinding
            )
            sessionQuiesced = true
            try FormalMacInteropFileSystem.cleanupRunDirectory(
                preparedRunDirectory,
                parent: runParent,
                runRef: configuration.runRef
            )
            runDirectory = nil

            stage = .identityFreeze
            let afterDigest = try FormalMacPersistentStateDigest.capture()
            guard afterDigest == beforeDigest else {
                throw FormalMacInteropError.inconsistentExistingIdentity
            }

            stage = .resultWrite
            let result = SuccessResult(
                runRef: configuration.runRef,
                sessionRef: terminalBinding.sessionRef,
                suite: terminalBinding.suite,
                suiteWireId: terminalBinding.suiteWireID,
                selectedIce: SelectedICE(
                    route: terminalBinding.selectedICE.route,
                    localCandidateType: terminalBinding.selectedICE.localCandidateType,
                    remoteCandidateType: terminalBinding.selectedICE.remoteCandidateType,
                    protocol: terminalBinding.selectedICE.networkProtocol
                ),
                transfers: Transfers(
                    androidToMac: androidToMac,
                    macToAndroid: macToAndroid
                ),
                identityState: IdentityState(
                    beforeDigest: beforeDigest,
                    afterDigest: afterDigest,
                    unchanged: true
                ),
                runOwnedPayloadCleaned: true
            )
            try FormalMacInteropFileSystem.writeExclusiveJSON(
                result,
                to: configuration.resultOutput
            )
            exit(EXIT_SUCCESS)
        } catch {
            var cleanupSucceeded = true
            if let formalManager = manager, !sessionQuiesced {
                do {
                    if let frozenBinding {
                        try await formalManager.retireAndQuiesceFormalInteropSession(
                            requiredBinding: frozenBinding
                        )
                    } else {
                        try await formalManager.retireAndQuiesceFormalInteropSessionAfterFailure()
                    }
                } catch {
                    cleanupSucceeded = false
                }
            }
            if cleanupSucceeded, let runDirectory {
                do {
                    try FormalMacInteropFileSystem.cleanupRunDirectory(
                        runDirectory,
                        parent: runParent,
                        runRef: configuration.runRef
                    )
                } catch {
                    cleanupSucceeded = false
                }
            }
            writeFailure(
                configuration: configuration,
                stage: cleanupSucceeded ? stage : .cleanup,
                error: cleanupSucceeded ? error : FormalMacInteropError.cleanupFailed
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func configureServerEnvironment(_ configuration: Configuration) throws {
        guard setenv(
            "SKYBRIDGE_SIGNALING_SERVER_URL",
            configuration.signalingHTTPSOrigin,
            1
        ) == 0,
        setenv(
            "SKYBRIDGE_SIGNALING_WEBSOCKET_URL",
            configuration.signalingWSSURL.absoluteString,
            1
        ) == 0 else {
            throw FormalMacInteropError.invalidConfiguration
        }
    }

    private static func formalRunParentDirectory() throws -> URL {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw FormalMacInteropError.invalidConfiguration
        }
        let parent = caches.appendingPathComponent(
            "com.skybridge.formal-interop",
            isDirectory: true
        )
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FormalMacInteropFileSystem.requirePrivateDirectory(parent)
        return parent.standardizedFileURL
    }

    private static func waitForConnectionCode(
        at url: URL,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        while ContinuousClock.now < deadline {
            do {
                let value = try readProtectedText(url, maximumBytes: 256, allowEmpty: false)
                guard CrossNetworkConnectionManager.isCanonicalFormalConnectionCode(value) else {
                    throw FormalMacInteropError.invalidConfiguration
                }
                return value
            } catch ProtectedReadError.notReady {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw FormalMacInteropError.invalidSession
    }

    private static func waitForHandshake(
        manager: CrossNetworkConnectionManager,
        deadline: ContinuousClock.Instant
    ) async throws {
        while ContinuousClock.now < deadline {
            switch manager.connectionStatus {
            case .failed:
                throw FormalMacInteropError.invalidSession
            case .connected:
                if case .handshakeComplete(_, let suite) = manager.readiness,
                   suite == "ML-KEM-768" {
                    return
                }
            case .idle, .generating, .waiting, .connecting:
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FormalMacInteropError.invalidSession
    }

    private static func waitForInboundEvidence(
        manager: CrossNetworkConnectionManager,
        deadline: ContinuousClock.Instant
    ) async throws -> FormalMacTransferEvidence {
        while ContinuousClock.now < deadline {
            if let evidence = try? manager.formalInboundEvidence() {
                return evidence
            }
            if case .failed = manager.connectionStatus {
                throw FormalMacInteropError.invalidTransferBinding
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FormalMacInteropError.invalidTransferBinding
    }

    private static func waitForFormalSessionBinding(
        manager: CrossNetworkConnectionManager,
        deadline: ContinuousClock.Instant
    ) async throws -> FormalMacSessionBinding {
        while ContinuousClock.now < deadline {
            do {
                return try await manager.captureFormalSessionBinding()
            } catch let error as FormalMacInteropError
                where FormalMacSessionBindingWaitPolicy.isRetryable(error) {
                if case .failed = manager.connectionStatus {
                    throw FormalMacInteropError.invalidSession
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw FormalMacInteropError.selectedICEUnavailable
    }

    private static func waitForFormalSessionRevalidation(
        manager: CrossNetworkConnectionManager,
        binding: FormalMacSessionBinding,
        deadline: ContinuousClock.Instant
    ) async throws {
        while ContinuousClock.now < deadline {
            do {
                try await manager.validateFormalSessionBinding(binding)
                return
            } catch let error as FormalMacInteropError
                where FormalMacSessionBindingWaitPolicy.isRetryable(error) {
                if case .failed = manager.connectionStatus {
                    throw FormalMacInteropError.invalidSession
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw FormalMacInteropError.selectedICEUnavailable
    }

    private static func readProtectedText(
        _ url: URL,
        maximumBytes: Int,
        allowEmpty: Bool
    ) throws -> String {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0 {
            if errno == ENOENT { throw ProtectedReadError.notReady }
            throw ProtectedReadError.unsafeFile
        }
        defer { _ = Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_uid == geteuid(),
              before.st_mode & 0o777 == 0o600,
              before.st_size >= 0,
              before.st_size <= maximumBytes else {
            throw ProtectedReadError.unsafeFile
        }
        if before.st_size == 0, !allowEmpty { throw ProtectedReadError.notReady }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: min(4_096, maximumBytes + 1))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw ProtectedReadError.unsafeFile }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= maximumBytes else { throw ProtectedReadError.tooLarge }
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              data.count == Int(after.st_size) else {
            throw ProtectedReadError.changedDuringRead
        }
        guard var value = String(data: data, encoding: .utf8) else {
            throw ProtectedReadError.invalidUTF8
        }
        if value.hasSuffix("\n") { value.removeLast() }
        guard !value.contains("\n"), !value.contains("\r"),
              allowEmpty || !value.isEmpty else {
            throw ProtectedReadError.unsafeFile
        }
        return value
    }

    private static func writeFailure(
        configuration: Configuration,
        stage: Stage,
        error: Error
    ) {
        let errorCode: String
        switch error {
        case FormalMacInteropError.missingExistingIdentity:
            errorCode = "missing_existing_identity"
        case FormalMacInteropError.inconsistentExistingIdentity:
            errorCode = "inconsistent_existing_identity"
        case FormalMacInteropError.missingExactPeerTrust:
            errorCode = "missing_exact_peer_trust"
        case FormalMacInteropError.duplicatePeerTrust:
            errorCode = "duplicate_peer_trust"
        case FormalMacInteropError.corruptPeerTrust:
            errorCode = "corrupt_peer_trust"
        case FormalMacInteropError.revokedPeerTrust:
            errorCode = "revoked_peer_trust"
        case FormalMacInteropError.selectedICEUnavailable:
            errorCode = "selected_ice_unavailable"
        case FormalMacInteropError.cleanupFailed:
            errorCode = "run_owned_cleanup_failed"
        case is ProtectedReadError:
            errorCode = "protected_file_read_failed"
        default:
            errorCode = "formal_interop_failed"
        }
        let failure = FailureResult(
            runRef: configuration.runRef,
            stage: stage.rawValue,
            errorCode: errorCode
        )
        do {
            try FormalMacInteropFileSystem.writeExclusiveJSON(
                failure,
                to: configuration.resultOutput
            )
        } catch {
            FileHandle.standardError.write(Data("unable to write formal host result\n".utf8))
        }
    }
}
