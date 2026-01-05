import Foundation

actor SystemOrchestrator {
    enum Domain { case deviceDiscovery, p2p, fileTransfer, performance }
    struct Budget { let interval: Double; let maxConcurrency: Int }
    nonisolated static let shared = SystemOrchestrator()
    private var domainBudgets: [Domain: Budget] = [:]
    private var currentModeName: String = "平衡"
    func reloadProfile(modeName: String) {
        currentModeName = modeName
        switch modeName {
        case "极致":
            domainBudgets = [
                .deviceDiscovery: Budget(interval: 0.1, maxConcurrency: 8),
                .p2p: Budget(interval: 0.05, maxConcurrency: 8),
                .fileTransfer: Budget(interval: 0.0, maxConcurrency: 8),
                .performance: Budget(interval: 0.5, maxConcurrency: 4)
            ]
        case "节能":
            domainBudgets = [
                .deviceDiscovery: Budget(interval: 1.0, maxConcurrency: 2),
                .p2p: Budget(interval: 0.5, maxConcurrency: 2),
                .fileTransfer: Budget(interval: 0.2, maxConcurrency: 2),
                .performance: Budget(interval: 2.0, maxConcurrency: 1)
            ]
        default:
            domainBudgets = [
                .deviceDiscovery: Budget(interval: 0.5, maxConcurrency: 4),
                .p2p: Budget(interval: 0.2, maxConcurrency: 4),
                .fileTransfer: Budget(interval: 0.1, maxConcurrency: 4),
                .performance: Budget(interval: 1.0, maxConcurrency: 2)
            ]
        }
    }
    func budget(for domain: Domain) -> Budget { domainBudgets[domain] ?? Budget(interval: 0.5, maxConcurrency: 2) }
    nonisolated func scheduleMain(after seconds: Double, block: @Sendable @escaping () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            let ns = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            if Task.isCancelled { return }
            block()
        }
    }
    nonisolated func scheduleGlobal(qos: DispatchQoS.QoSClass, after seconds: Double, block: @Sendable @escaping () -> Void) -> Task<Void, Never> {
        Task {
            let ns = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            if Task.isCancelled { return }
            DispatchQueue.global(qos: qos).async { block() }
        }
    }
}
