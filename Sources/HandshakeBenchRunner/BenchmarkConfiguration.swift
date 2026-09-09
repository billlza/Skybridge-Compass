import Foundation

struct BenchmarkConfiguration: Codable, Sendable {
    enum Profile: String, Codable { case core, contrast, full, comparison }
    enum OutputSet: String, Codable { case core, contrast }

    let iterations: Int
    let appleIterations: Int
    let warmup: Int
    let batches: Int
    let cooldownSeconds: Int
    let profile: Profile
    let outputSet: OutputSet
    let includeXWing: Bool
    let artifactDate: String
    let artifactsRoot: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        func value(_ key: String, alias: String) -> String? {
            environment[key] ?? environment[alias]
        }
        func integer(_ key: String, alias: String, defaultValue: Int, minimum: Int) throws -> Int {
            guard let raw = value(key, alias: alias) else { return defaultValue }
            guard let number = Int(raw), number >= minimum else {
                throw BenchmarkError.invalidConfiguration("\(key) must be an integer >= \(minimum)")
            }
            return number
        }
        iterations = try integer("SKYBRIDGE_BENCH_ITERATIONS", alias: "BENCH_ITERATIONS", defaultValue: 1000, minimum: 1)
        appleIterations = try integer("SKYBRIDGE_BENCH_APPLE_ITERATIONS", alias: "BENCH_APPLE_ITERATIONS", defaultValue: iterations, minimum: 1)
        warmup = try integer("SKYBRIDGE_BENCH_WARMUP", alias: "BENCH_WARMUP", defaultValue: 10, minimum: 0)
        batches = try integer("SKYBRIDGE_BENCH_RUNNER_BATCHES", alias: "BENCH_RUNNER_BATCHES", defaultValue: 1, minimum: 1)
        cooldownSeconds = try integer("SKYBRIDGE_BENCH_COOLDOWN_SECONDS", alias: "BENCH_COOLDOWN_SECONDS", defaultValue: 0, minimum: 0)
        guard let parsedProfile = Profile(rawValue: value("SKYBRIDGE_BENCH_PROFILE", alias: "BENCH_PROFILE") ?? "full") else {
            throw BenchmarkError.invalidConfiguration("Unknown benchmark profile")
        }
        profile = parsedProfile
        guard let parsedOutput = OutputSet(rawValue: value("SKYBRIDGE_BENCH_OUTPUT_SET", alias: "BENCH_OUTPUT_SET") ?? "core") else {
            throw BenchmarkError.invalidConfiguration("Unknown benchmark output set")
        }
        outputSet = parsedOutput
        switch value("SKYBRIDGE_BENCH_INCLUDE_XWING", alias: "BENCH_INCLUDE_XWING") ?? "0" {
        case "1", "true", "yes": includeXWing = true
        case "0", "false", "no": includeXWing = false
        default: throw BenchmarkError.invalidConfiguration("Invalid X-Wing inclusion flag")
        }
        // All measurements use inline, deterministic delivery. Async transport
        // needs an independently bounded lifecycle and is not this experiment.
        if let mode = environment["SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT"], mode != "1" {
            throw BenchmarkError.invalidConfiguration("Only deterministic in-memory transport is supported")
        }
        if profile == .comparison {
            guard appleIterations == iterations else {
                throw BenchmarkError.invalidConfiguration("Comparison requires equal provider sample counts")
            }
            guard environment["SB_ENABLE_QPERIAPT"] == "1" else {
                throw BenchmarkError.invalidConfiguration("Comparison requires SB_ENABLE_QPERIAPT=1 in this benchmark process")
            }
        }
        let date = value("ARTIFACT_DATE", alias: "SKYBRIDGE_ARTIFACT_DATE")
            ?? ISO8601DateFormatter().string(from: Date()).prefix(10).description
        guard !date.isEmpty, date.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else {
            throw BenchmarkError.invalidConfiguration("Artifact date must be a nonempty filename component")
        }
        artifactDate = date
        let root = value("ARTIFACTS_DIR", alias: "SKYBRIDGE_ARTIFACTS_DIR") ?? "Artifacts"
        guard !root.isEmpty else { throw BenchmarkError.invalidConfiguration("Artifact directory is empty") }
        artifactsRoot = URL(fileURLWithPath: root, isDirectory: true)
    }

    /// All six permutations balance first/second/third position and predecessor.
    /// A partial block is retained but must not be described as balanced.
    static func comparisonOrder(iteration: Int) -> [Int] {
        let orders = [[0, 1, 2], [2, 1, 0], [1, 2, 0], [0, 2, 1], [2, 0, 1], [1, 0, 2]]
        return orders[iteration % orders.count]
    }
}

enum BenchmarkError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case invalidMeasurement(String)
    case unavailableProvider(String)
    case timeout
    case closedTransport
    case missingReceiver
    case operationAndCloseFailed(operation: any Error, close: any Error)

    var description: String {
        switch self {
        case .invalidConfiguration(let detail): return "Invalid benchmark configuration: \(detail)"
        case .invalidMeasurement(let detail): return "Invalid handshake measurement: \(detail)"
        case .unavailableProvider(let detail): return "Provider unavailable: \(detail)"
        case .timeout: return "Handshake benchmark deadline exceeded"
        case .closedTransport: return "Benchmark transport is closed"
        case .missingReceiver: return "Benchmark transport receiver is missing"
        case .operationAndCloseFailed(let operation, let close):
            return "Artifact operation failed: \(operation); close also failed: \(close)"
        }
    }
}
