import Foundation
import Darwin
import SkyBridgeCore

@MainActor
private final class LocalLanInteropHostCoordinator {
    private let discoveryManager = DeviceDiscoveryManager()
    private let fileTransferManager = FileTransferManager.shared
    private let remoteControlManager = RemoteControlManager()

    private lazy var fileTransferListener = FileTransferListenerService(manager: fileTransferManager)
    private lazy var remoteControlServer = RemoteControlServer(manager: remoteControlManager)

    func start() async throws {
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

        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.SkyBridge.Compass/settings.json")

        emit("LocalLanInteropHost ready.")
        emit("Discovery/control: _skybridge._tcp on 9527")
        emit("File transfer: \(fileTransferListener.activePort ?? 8080)")
        emit("Remote desktop: \(remoteControlServer.activePort ?? 5901)")
        emit("Inbound files: \(inboundDirectory.path)")
        emit("Settings reference: \(settingsPath.path)")
        emit("Keep this process running while Azure relay and Windows client are active.")
    }

    private func emit(_ line: String) {
        let data = Data((line + "\n").utf8)
        FileHandle.standardOutput.write(data)
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
