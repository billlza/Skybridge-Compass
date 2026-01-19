#!/usr/bin/env swift
// Network Condition Benchmark - With Retransmission Model
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
    let retryCount: Int

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
        "\(condition.rawValue),\(suiteType),\(totalAttempts),\(successCount),\(failureCount),\(timeoutCount),\(completionRate),\(meanLatency),\(percentile(0.50)),\(percentile(0.95)),\(percentile(0.99)),\(retryCount)"
    }
}

class NetworkSimulator {
    let condition: NetworkCondition
    let maxRetries: Int
    let retryDelayMs: Int

    init(condition: NetworkCondition, maxRetries: Int = 2, retryDelayMs: Int = 100) {
        self.condition = condition
        self.maxRetries = maxRetries
        self.retryDelayMs = retryDelayMs
    }

    /// Simulate sending a message with retransmission
    func simulateSendWithRetry(messageSize: Int) -> (delivered: Bool, latencyMs: Double, retries: Int) {
        var retries = 0
        var totalLatency: Double = 0

        for attempt in 0...maxRetries {
            // Packet loss check
            if Double.random(in: 0...1) < condition.lossRate {
                if attempt < maxRetries {
                    retries += 1
                    totalLatency += Double(retryDelayMs)  // Retry timeout
                    continue
                } else {
                    return (false, totalLatency, retries)
                }
            }

            // Success - add transmission latency
            let baseLatency = condition.baseLatencyMs
            let jitter = condition.jitterMs
            let actualLatency = baseLatency + Int.random(in: -jitter...jitter)

            var reorderDelay = 0
            if Double.random(in: 0...1) < condition.reorderRate {
                reorderDelay = Int.random(in: 50...150)
            }

            totalLatency += Double(max(0, actualLatency + reorderDelay))
            return (true, totalLatency, retries)
        }

        return (false, totalLatency, retries)
    }
}

struct HandshakeSimulator {
    let condition: NetworkCondition
    let suiteType: String
    let timeoutMs: Int
    let maxRetries: Int

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

    func runHandshake() -> (success: Bool, latencyMs: Double, failureReason: String?, retries: Int) {
        let simulator = NetworkSimulator(condition: condition, maxRetries: maxRetries)
        var totalLatency: Double = 0
        var totalRetries = 0

        // MessageA
        let (msgADelivered, msgALatency, msgARetries) = simulator.simulateSendWithRetry(messageSize: messageASize)
        totalRetries += msgARetries
        if !msgADelivered { return (false, 0, "messageA_lost", totalRetries) }
        totalLatency += msgALatency
        if totalLatency > Double(timeoutMs) { return (false, totalLatency, "timeout", totalRetries) }

        // MessageB
        let (msgBDelivered, msgBLatency, msgBRetries) = simulator.simulateSendWithRetry(messageSize: messageBSize)
        totalRetries += msgBRetries
        if !msgBDelivered { return (false, totalLatency, "messageB_lost", totalRetries) }
        totalLatency += msgBLatency
        if totalLatency > Double(timeoutMs) { return (false, totalLatency, "timeout", totalRetries) }

        // Finished R2I
        let (finR2IDelivered, finR2ILatency, finR2IRetries) = simulator.simulateSendWithRetry(messageSize: 38)
        totalRetries += finR2IRetries
        if !finR2IDelivered { return (false, totalLatency, "finished_lost", totalRetries) }
        totalLatency += finR2ILatency

        // Finished I2R
        let (finI2RDelivered, finI2RLatency, finI2RRetries) = simulator.simulateSendWithRetry(messageSize: 38)
        totalRetries += finI2RRetries
        if !finI2RDelivered { return (false, totalLatency, "finished_lost", totalRetries) }
        totalLatency += finI2RLatency

        if totalLatency > Double(timeoutMs) { return (false, totalLatency, "timeout", totalRetries) }
        return (true, totalLatency, nil, totalRetries)
    }
}

func runBenchmark(iterations: Int, timeoutMs: Int, maxRetries: Int) -> [NetworkConditionStats] {
    let suiteTypes = ["classic", "pqc_liboqs", "pqc_cryptokit"]
    var allStats: [NetworkConditionStats] = []

    print("[NET-BENCH] Network Condition Benchmarks (with retransmission)")
    print("[NET-BENCH] Iterations: \(iterations), Timeout: \(timeoutMs)ms, Max Retries: \(maxRetries)")
    print("")

    for condition in NetworkCondition.allCases {
        for suiteType in suiteTypes {
            let simulator = HandshakeSimulator(condition: condition, suiteType: suiteType, timeoutMs: timeoutMs, maxRetries: maxRetries)

            var successCount = 0
            var failureCount = 0
            var timeoutCount = 0
            var latencies: [Double] = []
            var totalRetries = 0

            for _ in 0..<iterations {
                let (success, latency, failureReason, retries) = simulator.runHandshake()
                totalRetries += retries
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
                latencies: latencies,
                retryCount: totalRetries
            )
            allStats.append(stats)

            let completionPct = (stats.completionRate * 10000).rounded() / 100
            let p50 = stats.percentile(0.50).rounded()
            let p95 = stats.percentile(0.95).rounded()
            print("[NET-BENCH] \(condition.rawValue)/\(suiteType): \(completionPct)%, p50=\(p50)ms, p95=\(p95)ms, retries=\(totalRetries)")
        }
    }

    return allStats
}

func writeCSV(_ stats: [NetworkConditionStats], iterations: Int, timeoutMs: Int, maxRetries: Int) throws {
    let artifactsDir = FileManager.default.currentDirectoryPath + "/Artifacts"
    try FileManager.default.createDirectory(atPath: artifactsDir, withIntermediateDirectories: true)

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let dateString = dateFormatter.string(from: Date())

    let csvPath = "\(artifactsDir)/network_condition_\(dateString).csv"

    var content = "# Network Condition Benchmark Results (with retransmission)\n"
    content += "# Date: \(dateString)\n"
    content += "# Iterations: \(iterations), Timeout: \(timeoutMs)ms, Max Retries: \(maxRetries)\n"
    content += "condition,suite_type,n_attempts,n_success,n_failure,n_timeout,completion_rate,mean_latency_ms,p50_latency_ms,p95_latency_ms,p99_latency_ms,total_retries\n"

    for stat in stats {
        content += stat.csvRow + "\n"
    }

    try content.write(toFile: csvPath, atomically: true, encoding: .utf8)
    print("\n[NET-BENCH] CSV written to: \(csvPath)")
}

func printSummaryTable(_ stats: [NetworkConditionStats]) {
    print("\n" + String(repeating: "=", count: 95))
    print("NETWORK CONDITION BENCHMARK RESULTS (with retransmission, max 2 retries)")
    print(String(repeating: "=", count: 95))
    print("Condition            Suite           Complete%   P50(ms)   P95(ms)   Mean(ms)   Retries")
    print(String(repeating: "-", count: 95))

    for stat in stats {
        let completePct = (stat.completionRate * 10000).rounded() / 100
        let p50 = (stat.percentile(0.50) * 10).rounded() / 10
        let p95 = (stat.percentile(0.95) * 10).rounded() / 10
        let mean = (stat.meanLatency * 10).rounded() / 10
        print("\(stat.condition.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)) \(stat.suiteType.padding(toLength: 15, withPad: " ", startingAt: 0)) \(completePct)%      \(p50)       \(p95)       \(mean)       \(stat.retryCount)")
    }
    print(String(repeating: "=", count: 95))

    // Paper validation
    print("\n[PAPER VALIDATION - 1% loss (mild) condition, claims >98%]")
    for stat in stats where stat.condition == .mild {
        let completePct = (stat.completionRate * 100 * 100).rounded() / 100
        let passStr = stat.completionRate > 0.98 ? "PASS ✓" : "FAIL ✗"
        print("  \(stat.suiteType): \(completePct)% - \(passStr)")
    }

    print("\n[LATENCY INCREASE - p95 from ideal to mild]")
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
let iterations = Int(ProcessInfo.processInfo.environment["ITERATIONS"] ?? "") ?? 10000
let timeoutMs = Int(ProcessInfo.processInfo.environment["TIMEOUT_MS"] ?? "") ?? 5000
let maxRetries = Int(ProcessInfo.processInfo.environment["MAX_RETRIES"] ?? "") ?? 2

let stats = runBenchmark(iterations: iterations, timeoutMs: timeoutMs, maxRetries: maxRetries)

do {
    try writeCSV(stats, iterations: iterations, timeoutMs: timeoutMs, maxRetries: maxRetries)
} catch {
    print("[NET-BENCH] Error writing CSV: \(error)")
}

printSummaryTable(stats)
