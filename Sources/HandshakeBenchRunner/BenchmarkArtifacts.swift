import Foundation

struct BenchmarkSample: Codable, Sendable {
    let sequence: Int
    let batch: Int
    let iteration: Int
    let provider: String
    let suiteWireID: UInt16
    let latencyMS: Double
    let rttMS: Double
    let messageABytes: Int
    let messageBBytes: Int
    let finishedBytes: Int
}

struct BenchmarkStatistics: Sendable {
    let mean: Double
    let stdDev: Double
    let p50: Double
    let p95: Double
    let p99: Double

    init(samples: [Double]) throws {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw BenchmarkError.invalidMeasurement("Statistics require nonempty finite, nonnegative samples")
        }
        let sorted = samples.sorted()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)
        guard mean.isFinite, variance.isFinite else {
            throw BenchmarkError.invalidMeasurement("Statistics overflow")
        }
        self.mean = mean
        stdDev = sqrt(variance)
        // Preserve the existing empirical lower-order-statistic convention.
        p50 = sorted[Int(Double(sorted.count - 1) * 0.50)]
        p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
    }

    var csv: String { "\(mean),\(stdDev),\(p50),\(p95),\(p99)" }
}

/// One invocation owns a new directory. Raw measurements survive a later
/// failure; completion.json is written only after every requested sample and
/// summary has been written successfully. No output-directory fallback.
struct BenchmarkArtifacts: Sendable {
    let directory: URL
    private let configuration: BenchmarkConfiguration

    init(configuration: BenchmarkConfiguration) throws {
        self.configuration = configuration
        directory = configuration.artifactsRoot.appendingPathComponent("handshake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeJSON(configuration, filename: "configuration.json")
        try Data().write(to: directory.appendingPathComponent("samples.jsonl"), options: .withoutOverwriting)
    }

    func record(_ sample: BenchmarkSample) throws {
        let data = try JSONEncoder().encode(sample) + Data([10])
        try Self.append(data, to: directory.appendingPathComponent("samples.jsonl"))
    }

    func writeSummary(provider: String, samples: [BenchmarkSample]) throws {
        let latency = try BenchmarkStatistics(samples: samples.map(\.latencyMS))
        let rtt = try BenchmarkStatistics(samples: samples.map(\.rttMS))
        let suffix = configuration.outputSet == .contrast ? "_contrast" : ""
        let header = "configuration,iteration_count,mean_ms,stddev_ms,p50_ms,p95_ms,p99_ms\n"
        try appendCSV(header: header, row: "\(provider),\(samples.count),\(latency.csv)\n", filename: "handshake_bench\(suffix)_\(configuration.artifactDate).csv")
        try appendCSV(header: header, row: "\(provider),\(samples.count),\(rtt.csv)\n", filename: "handshake_rtt\(suffix)_\(configuration.artifactDate).csv")
        guard let first = samples.first else { throw BenchmarkError.invalidMeasurement("Missing wire sample") }
        // Every sample retains its own wire sizes, including variable padding.
        let total = first.messageABytes + first.messageBBytes + first.finishedBytes
        try appendCSV(
            header: "configuration,messageA_bytes,messageB_bytes,finished_bytes,total_bytes\n",
            row: "\(provider),\(first.messageABytes),\(first.messageBBytes),\(first.finishedBytes),\(total)\n",
            filename: "handshake_wire\(suffix)_\(configuration.artifactDate).csv"
        )
    }

    func writeJSON<T: Encodable>(_ value: T, filename: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(filename), options: .withoutOverwriting)
    }

    private func appendCSV(header: String, row: String, filename: String) throws {
        // Existing paper profiles still feed date-based CSV consumers. The
        // comparison profile never appends to those legacy aggregate files.
        let destinations = configuration.profile == .comparison
            ? [directory] : [directory, configuration.artifactsRoot]
        for destination in destinations {
            let path = destination.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: path.path) {
                try Data(header.utf8).write(to: path, options: .withoutOverwriting)
            }
            try Self.append(Data(row.utf8), to: path)
        }
    }

    static func append(_ data: Data, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path)
        let operation = Result {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        let close = Result { try handle.close() }
        switch (operation, close) {
        case (.success, .success): return
        case (.failure(let error), .success), (.success, .failure(let error)): throw error
        case (.failure(let operation), .failure(let close)):
            throw BenchmarkError.operationAndCloseFailed(operation: operation, close: close)
        }
    }
}
