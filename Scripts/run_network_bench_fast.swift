#!/usr/bin/env swift
// Network Condition Benchmark - Fast Simulation
import Foundation

enum NetworkCondition: String, CaseIterable {
    case ideal = "ideal"
    case mild = "mild_1pct_50ms"
    case moderate = "moderate_3pct_100ms"
    case severe = "severe_5pct_200ms"
    case reorder = "reorder_10pct"

    var lossRate: Double {
        switch self {
        case .ideal: return 0.0
        case .mild: return 0.01
        case .moderate: return 0.03
        case .severe: return 0.05
        case .reorder: return 0.0
        }
    }

    var baseLatencyMs: Int {
        switch self {
        case .ideal: return 0
        case .mild: return 50
        case .moderate: return 100
        case .severe: return 200
        case .reorder: return 50
        }
    }

    var jitterMs: Int {
        switch self {
        case .ideal: return 0
        case .mild: return 20
        case .moderate: return 50
        case .severe: return 100
        case .reorder: return 20
        }
    }

    var reorderRate: Double {
        switch self {
        case .reorder: return 0.10
        default: return 0.0
        }
    }
}

struct NetworkConditionStats {
    let condition: NetworkCondition
    let suiteType: String
    let totalAttempts: Int
    let successCount: Int
    let failureCount: Int
    let timeoutCount: Int
    let latencies: [Double]

    var completionRate: Double {
        guard totalAttempts > 0 else { return 0.0 }
        return Double(successCount) / Double(totalAttempts)
    }

    func percentile(_ p: Double) -> Double {
        guard !latencies.isEmpty else { return 0.0 }
        let sorted = latencies.sorted()
        let idx = Int(Double(sorted.count) * p)
        return sorted[min(idx, sorted.count - 1)]
    }

    var meanLatency: Double {
        guard !latencies.isEmpty else { return 0.0 }
        return latencies.reduce(0, +) / Double(latencies.count)
    }

    var csvRow: String {
        "\(condition.rawValue),\(suiteType),\(totalAttempts),\(successCount),\(failureCount),\(timeoutCount),\(completionRate),\(meanLatency),\(percentile(0.50)),\(percentile(0.95)),\(percentile(0.99))"
    }
}

class NetworkSimulator {
    let condition: NetworkCondition

    init(condition: NetworkCondition) {
        self.condition = condition
    }

    func simulateSend(messageSize: Int) -> (delivered: Bool, latencyMs: Double) {
        if Double.random(in: 0...1) < condition.lossRate {
            return (false, 0)
        }

        let baseLatency = condition.baseLatencyMs
        let jitter = condition.jitterMs
        let actualLatency = baseLatency + Int.random(in: -jitter...jitter)

        var reorderDelay = 0
        if Double.random(in: 0...1) < condition.reorderRate {
            reorderDelay = Int.random(in: 50...150)
        }

        let totalLatency = max(0, actualLatency + reorderDelay)
        return (true, Double(totalLatency))
    }
}

struct HandshakeSimulator {
    let condition: NetworkCondition
    let suiteType: String
    let timeoutMs: Int

    var messageASize: Int {
        switch suiteType {
        case "classic": return 337
        case "pqc_liboqs", "pqc_cryptokit": return 6560
        default: return 500
        }
    }

    var messageBSize: Int {
        switch suiteType {
        case "classic": return 380
        case "pqc_liboqs": return 5493
        case "pqc_cryptokit": return 5510
        default: return 500
        }
    }

    func runHandshake() -> (success: Bool, latencyMs: Double, failureReason: String?) {
        let simulator = NetworkSimulator(condition: condition)
        var totalLatency: Double = 0

        // MessageA
        let (msgADelivered, msgALatency) = simulator.simulateSend(messageSize: messageASize)
        if !msgADelivered { return (false, 0, "messageA_lost") }
        totalLatency += msgALatency
        if totalLatency > Double(timeoutMs) { return (false, totalLatency, "timeout") }

        // MessageB
        let (msgBDelivered, msgBLatency) = simulator.simulateSend(messageSize: messageBSize)
        if !msgBDelivered { return (false, totalLatency, "messageB_lost") }
        totalLatency += msgBLatency
        if totalLatency > Double(timeoutMs) { return (false, totalLatency, "timeout") }

        // Finished R2I
        let (finR2IDelivered, finR2ILatency) = simulator.simulateSend(messageSize: 38)
        if !finR2IDelivered { return (false, totalLatency, "finished_lost") }
        totalLatency += finR2ILatency

        // Finished I2R
        let (finI2RDelivered, finI2RLatency) = simulator.simulateSend(messageSize: 38)
        if !finI2RDelivered { return (false, totalLatency, "finished_lost") }
        totalLatency += finI2RLatency

        if totalLatency > Double(timeoutMs) { return (false, totalLatency, "timeout") }
        return (true, totalLatency, nil)
    }
}

func runBenchmark(iterations: Int, timeoutMs: Int) -> [NetworkConditionStats] {
    let suiteTypes = ["classic", "pqc_liboqs", "pqc_cryptokit"]
    var allStats: [NetworkConditionStats] = []

    print("[NET-BENCH] Starting network condition benchmarks")
    print("[NET-BENCH] Iterations per scenario: \(iterations)")
    print("[NET-BENCH] Timeout: \(timeoutMs)ms")
    print("")

    for condition in NetworkCondition.allCases {
        for suiteType in suiteTypes {
            let simulator = HandshakeSimulator(condition: condition, suiteType: suiteType, timeoutMs: timeoutMs)

            var successCount = 0
            var failureCount = 0
            var timeoutCount = 0
            var latencies: [Double] = []

            for _ in 0..<iterations {
                let (success, latency, failureReason) = simulator.runHandshake()
                if success {
                    successCount += 1
                    latencies.append(latency)
                } else if failureReason?.contains("timeout") == true {
                    timeoutCount += 1
                } else {
                    failureCount += 1
                }
            }

            let stats = NetworkConditionStats(
                condition: condition,
                suiteType: suiteType,
                totalAttempts: iterations,
                successCount: successCount,
                failureCount: failureCount,
                timeoutCount: timeoutCount,
                latencies: latencies
            )
            allStats.append(stats)

            let completionPct = (stats.completionRate * 100).rounded() / 1
            let p50 = stats.percentile(0.50).rounded()
            let p95 = stats.percentile(0.95).rounded()
            print("[NET-BENCH] \(condition.rawValue)/\(suiteType): completion=\(completionPct)%, p50=\(p50)ms, p95=\(p95)ms")
        }
    }

    return allStats
}

func writeCSV(_ stats: [NetworkConditionStats], iterations: Int, timeoutMs: Int) throws {
    let artifactsDir = FileManager.default.currentDirectoryPath + "/Artifacts"
    try FileManager.default.createDirectory(atPath: artifactsDir, withIntermediateDirectories: true)

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let dateString = dateFormatter.string(from: Date())

    let csvPath = "\(artifactsDir)/network_condition_\(dateString).csv"

    var content = "# Network Condition Benchmark Results\n"
    content += "# Date: \(dateString)\n"
    content += "# Iterations: \(iterations), Timeout: \(timeoutMs)ms\n"
    content += "condition,suite_type,n_attempts,n_success,n_failure,n_timeout,completion_rate,mean_latency_ms,p50_latency_ms,p95_latency_ms,p99_latency_ms\n"

    for stat in stats {
        content += stat.csvRow + "\n"
    }

    try content.write(toFile: csvPath, atomically: true, encoding: .utf8)
    print("\n[NET-BENCH] CSV written to: \(csvPath)")
}

func printSummaryTable(_ stats: [NetworkConditionStats]) {
    print("\n" + String(repeating: "=", count: 90))
    print("NETWORK CONDITION BENCHMARK RESULTS")
    print(String(repeating: "=", count: 90))
    print("Condition            Suite           Complete%   P50(ms)   P95(ms)   P99(ms)   Mean(ms)")
    print(String(repeating: "-", count: 90))

    for stat in stats {
        let completePct = (stat.completionRate * 10000).rounded() / 100
        let p50 = (stat.percentile(0.50) * 10).rounded() / 10
        let p95 = (stat.percentile(0.95) * 10).rounded() / 10
        let p99 = (stat.percentile(0.99) * 10).rounded() / 10
        let mean = (stat.meanLatency * 10).rounded() / 10
        print("\(stat.condition.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)) \(stat.suiteType.padding(toLength: 15, withPad: " ", startingAt: 0)) \(completePct)%      \(p50)       \(p95)       \(p99)       \(mean)")
    }
    print(String(repeating: "=", count: 90))

    // Paper validation
    print("\n[PAPER VALIDATION - 1% loss (mild) condition]")
    for stat in stats where stat.condition == .mild {
        let completePct = (stat.completionRate * 100).rounded()
        let passStr = stat.completionRate > 0.98 ? "PASS" : "CHECK"
        print("  \(stat.suiteType): \(completePct)% completion - \(passStr)")
    }

    print("\n[LATENCY INCREASE ANALYSIS - p95 increase from ideal to mild]")
    let idealStats = stats.filter { $0.condition == .ideal }
    let mildStats = stats.filter { $0.condition == .mild }
    for suite in ["classic", "pqc_liboqs", "pqc_cryptokit"] {
        if let ideal = idealStats.first(where: { $0.suiteType == suite }),
           let mild = mildStats.first(where: { $0.suiteType == suite }) {
            let latencyIncrease = mild.percentile(0.95) - ideal.percentile(0.95)
            let increaseRounded = (latencyIncrease * 10).rounded() / 10
            print("  \(suite): +\(increaseRounded)ms")
        }
    }
}

// Main execution
let iterations = Int(ProcessInfo.processInfo.environment["ITERATIONS"] ?? "") ?? 1000
let timeoutMs = Int(ProcessInfo.processInfo.environment["TIMEOUT_MS"] ?? "") ?? 5000

let stats = runBenchmark(iterations: iterations, timeoutMs: timeoutMs)

do {
    try writeCSV(stats, iterations: iterations, timeoutMs: timeoutMs)
} catch {
    print("[NET-BENCH] Error writing CSV: \(error)")
}

printSummaryTable(stats)
