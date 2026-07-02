import Foundation
import SkyBridgeCore

#if os(macOS)
@MainActor
final class OperatorControlServerBootstrap {
    static let shared = OperatorControlServerBootstrap()

    private var server: OperatorControlServer?
    private var startTask: Task<Void, Never>?

    private init() {}

    func startIfNeeded() {
        guard server == nil, startTask == nil else { return }

        let router = CrossnetControlRouter(runtime: .live())
        do {
            let candidateServer = try OperatorControlServer(router: router)
            startTask = Task { [weak self, candidateServer] in
                do {
                    try await candidateServer.start()
                    await MainActor.run {
                        self?.server = candidateServer
                        self?.startTask = nil
                    }
                } catch {
                    await MainActor.run {
                        self?.startTask = nil
                    }
                    SkyBridgeLogger.system.error(
                        "crossnet-control server failed to start: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        } catch {
            SkyBridgeLogger.system.error(
                "crossnet-control server could not resolve socket path: \(error.localizedDescription, privacy: .private)"
            )
        }
    }
}
#endif
