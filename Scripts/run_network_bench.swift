#!/usr/bin/env swift
// SPDX-License-Identifier: MIT
// Network Condition Benchmark - Standalone Script
// Simulates network conditions to measure handshake completion rates

import Foundation

// MARK: - Network Condition Configuration

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

// MARK: - Statistics

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

    var p50Latency: Double {
        guard !latencies.isEmpty else { return 0.0 }
        let sorted = latencies.sorted()
        return sorted[sorted.count / 2]
    }

    var p95Latency: Double {
        guard !latencies.isEmpty else { return 0.0 }
        let sorted = latencies.sorted()
        let idx = Int(Double(sorted.count) * 0.95)
        return sorted[min(idx, sorted.count - 1)]
    }

    var p99Latency: Double {
        guard !latencies.isEmpty else { return 0.0 }
        let sorted = latencies.sorted()
        let idx = Int(Double(sorted.count) * 0.99)
        return sorted[min(idx, sorted.count - 1)]
    }

    var meanLatency: Double {
        guard !latencies.isEmpty else { return 0.0 }
        return latencies.reduce(0, +) / Double(latencies.count)
    }

    var csvRow: String {
        String(format: "%@,%@,%d,%d,%d,%d,%.4f,%.2f,%.2f,%.2f,%.2f",
               condition.rawValue,
               suiteType,
               totalAttempts,
               successCount,
               failureCount,
               timeoutCount,
               completionRate,
               meanLatency,
               p50Latency,
               p95Latency,
               p99Latency)
    }
}

// MARK: - Network Simulation

class NetworkSimulator {
    let condition: NetworkCondition

    init(condition: NetworkCondition) {
        self.condition = condition
    }

    /// Simulate sending a message, returns (delivered, latencyMs)
    func simulateSend(messageSize: Int) async -> (delivered: Bool, latencyMs: Double) {
        // Simulate packet loss
        if Double.random(in: 0...1) < condition.lossRate {
            return (false, 0)
        }

        // Simulate latency + jitter
        let baseLatency = condition.baseLatencyMs
        let jitter = condition.jitterMs
        let actualLatency = baseLatency + Int.random(in: -jitter...jitter)

        // Simulate reordering delay
        var reorderDelay = 0
        if Double.random(in: 0...1) < condition.reorderRate {
            reorderDelay = Int.random(in: 50...150)
        }

        let totalLatency = max(0, actualLatency + reorderDelay)

        if totalLatency > 0 {
            try? await Task.sleep(nanoseconds: UInt64(totalLatency) * 1_000_000)
        }

        return (true, Double(totalLatency))
    }
}

// MARK: - Handshake Simulation

struct HandshakeSimulator {
    let condition: NetworkCondition
    let suiteType: String
    let timeoutMs: Int

    // Message sizes from paper Table S3
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

    var finishedSize: Int { return 76 }  // Two finished frames

    func runHandshake() async -> (success: Bool, latencyMs: Double, failureReason: String?) {
        let simulator = NetworkSimulator(condition: condition)
        var totalLatency: Double = 0

        // MessageA: Initiator -> Responder
        let (msgADelivered, msgALatency) = await simulator.simulateSend(messageSize: messageASize)
        if !msgADelivered {
            return (false, 0, "messageA_lost")
        }
        totalLatency += msgALatency

        // Check timeout
        if totalLatency > Double(timeoutMs) {
            return (false, totalLatency, "timeout_after_msgA")
        }

        // MessageB: Responder -> Initiator
        let (msgBDelivered, msgBLatency) = await simulator.simulateSend(messageSize: messageBSize)
        if !msgBDelivered {
            return (false, totalLatency, "messageB_lost")
        }
        totalLatency += msgBLatency

        // Check timeout
        if totalLatency > Double(timeoutMs) {
            return (false, totalLatency, "timeout_after_msgB")
        }

        // Finished frames (R2I + I2R)
        let (finR2IDelivered, finR2ILatency) = await simulator.simulateSend(messageSize: finishedSize / 2)
        if !finR2IDelivered {
            return (false, totalLatency, "finished_r2i_lost")
        }
        totalLatency += finR2ILatency

        let (finI2RDelivered, finI2RLatency) = await simulator.simulateSend(messageSize: finishedSize / 2)
        if !finI2RDelivered {
            return (false, totalLatency, "finished_i2r_lost")
        }
        totalLatency += finI2RLatency

        // Check final timeout
        if totalLatency > Double(timeoutMs) {
            return (false, totalLatency, "timeout_after_finished")
        }

        return (true, totalLatency, nil)
    }
}

// MARK: - Benchmark Runner

func runBenchmark(iterations: Int, timeoutMs: Int) async -> [NetworkConditionStats] {
    let suiteTypes = ["classic", "pqc_liboqs", "pqc_cryptokit"]
    var allStats: [NetworkConditionStats] = []

    print("[NET-BENCH] Starting network condition benchmarks")
    print("[NET-BENCH] Iterations per scenario: \(iterations)")
    print("[NET-BENCH] Timeout: \(timeoutMs)ms")
    print("")

    for condition in NetworkCondition.allCases {
        for suiteType in suiteTypes {
            print("[NET-BENCH] Testing \(condition.rawValue) with \(suiteType)...")

            let simulator = HandshakeSimulator(
                condition: condition,
                suiteType: suiteType,
                timeoutMs: timeoutMs
            )

            var successCount = 0
            var failureCount = 0
            var timeoutCount = 0
            var latencies: [Double] = []

            for _ in 0..<iterations {
                let (success, latency, failureReason) = await simulator.runHandshake()

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

            print("[NET-BENCH] \(condition.rawValue)/\(suiteType): " +
                  "completion=\(String(format: "%.2f%%", stats.completionRate * 100)), " +
                  "p50=\(String(format: "%.1fms", stats.p50Latency)), " +
                  "p95=\(String(format: "%.1fms", stats.p95Latency))")
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
    print("\n" + String(repeating: "=", count: 100))
    print("NETWORK CONDITION BENCHMARK RESULTS")
    print(String(repeating: "=", count: 100))
    print(String(format: "%-20s %-15s %10s %10s %10s %10s %10s",
                 "Condition", "Suite", "Complete%", "P50(ms)", "P95(ms)", "P99(ms)", "Mean(ms)"))
    print(String(repeating: "-", count: 100))

    for stat in stats {
        print(String(format: "%-20s %-15s %9.2f%% %10.1f %10.1f %10.1f %10.1f",
                     stat.condition.rawValue,
                     stat.suiteType,
                     stat.completionRate * 100,
                     stat.p50Latency,
                     stat.p95Latency,
                     stat.p99Latency,
                     stat.meanLatency))
    }
    print(String(repeating: "=", count: 100))

    // Print summary for paper claims
    print("\n[PAPER VALIDATION]")
    for stat in stats where stat.condition == .mild && stat.suiteType.contains("pqc") {
        let passStr = stat.completionRate > 0.98 ? "PASS ✓" : "FAIL ✗"
        print("  \(stat.condition.rawValue)/\(stat.suiteType): \(String(format: "%.2f%%", stat.completionRate * 100)) - Paper claims >98% - \(passStr)")
    }
}

// MARK: - Main

func runMain() async {
    let iterations = Int(ProcessInfo.processInfo.environment["ITERATIONS"] ?? "") ?? 1000
    let timeoutMs = Int(ProcessInfo.processInfo.environment["TIMEOUT_MS"] ?? "") ?? 5000

    let stats = await runBenchmark(iterations: iterations, timeoutMs: timeoutMs)

    do {
        try writeCSV(stats, iterations: iterations, timeoutMs: timeoutMs)
    } catch {
        print("[NET-BENCH] Error writing CSV: \(error)")
    }

    printSummaryTable(stats)
}

// Entry point
let semaphore = DispatchSemaphore(value: 0)
Task {
    await runMain()
    semaphore.signal()
}
semaphore.wait()
