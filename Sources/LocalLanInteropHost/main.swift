import Foundation
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

        print("LocalLanInteropHost ready.")
        print("Discovery/control: _skybridge._tcp on 9527")
        print("File transfer: 8080")
        print("Remote desktop: 5901")
        print("Inbound files: \(inboundDirectory.path)")
        print("Settings reference: \(settingsPath.path)")
        print("Keep this process running while Azure relay and Windows client are active.")
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
