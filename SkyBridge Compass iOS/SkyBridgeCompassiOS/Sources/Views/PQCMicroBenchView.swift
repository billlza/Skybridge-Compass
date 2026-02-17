import SwiftUI
import Foundation
import UIKit

@available(iOS 17.0, *)
struct PQCMicroBenchView: View {
    @State private var artifactDate: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }()
    @State private var deviceLabel: String = PQCMicroBenchView.defaultDeviceLabel()
    @State private var warmupText: String = "10"
    @State private var iterationsText: String = "1000"
    @State private var batchesText: String = "3"

    @State private var isRunning = false
    @State private var progressText = ""
    @State private var errorText: String?
    @State private var artifactURL: URL?

    var body: some View {
        List {
            Section("配置") {
                TextField("ARTIFACT_DATE (YYYY-MM-DD)", text: $artifactDate)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("device label", text: $deviceLabel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("warmup", text: $warmupText)
                    .keyboardType(.numberPad)

                TextField("N (iterations)", text: $iterationsText)
                    .keyboardType(.numberPad)

                TextField("batches", text: $batchesText)
                    .keyboardType(.numberPad)
            }

            Section("运行") {
                Button {
                    Task { await runBenchmarks() }
                } label: {
                    HStack {
                        if isRunning {
                            ProgressView().padding(.trailing, 8)
                        }
                        Text(isRunning ? "运行中..." : "开始 microbench")
                    }
                }
                .disabled(isRunning)

                if !progressText.isEmpty {
                    Text(progressText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }

            Section("导出") {
                if let artifactURL {
                    ShareLink(item: artifactURL) {
                        Label("导出 JSON (schema v3)", systemImage: "square.and.arrow.up")
                    }
                    Text(artifactURL.lastPathComponent)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text("尚未生成 artifact")
                        .foregroundColor(.secondary)
                }
                Text("导出到 Mac 后放入 Artifacts/，然后运行 python3 Scripts/aggregate_ios_microbench.py 生成主文表格。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("PQC Self-test/Bench")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runBenchmarks() async {
        errorText = nil
        artifactURL = nil
        progressText = ""
        isRunning = true
        defer { isRunning = false }

        let stamp = sanitize(artifactDate)
        let label = sanitize(deviceLabel)
        guard !label.isEmpty else {
            errorText = "device label is empty"
            return
        }
        guard let warmup = Int(warmupText), warmup >= 0 else {
            errorText = "invalid warmup"
            return
        }
        guard let iterations = Int(iterationsText), iterations > 0 else {
            errorText = "invalid N"
            return
        }
        guard let batches = Int(batchesText), batches > 0 else {
            errorText = "invalid batches"
            return
        }

        do {
            let suites = try await buildSuiteRuntimes()
            var suiteResults: [IOSMicrobenchSuiteResult] = []
            let totalOps = max(1, suites.count * BenchOperation.allCases.count * batches)
            var completedOps = 0

            for suite in suites {
                if let unavailable = suite.unavailableReason {
                    suiteResults.append(
                        IOSMicrobenchSuiteResult(
                            suiteId: suite.suiteId,
                            suiteLabel: suite.suiteLabel,
                            kemSuite: suite.kemSuite,
                            sigSuite: suite.sigSuite,
                            status: "unavailable",
                            note: unavailable,
                            operations: []
                        )
                    )
                    continue
                }

                guard let runtime = suite.runtime else { continue }
                let payload = Data(repeating: 0xA5, count: 1024)
                let hpkeInfo = Data("ios-bench-info".utf8)
                let verifySignature = try await runtime.provider.sign(data: payload, using: .softwareKey(runtime.sigPrivateKey))

                var operationResults: [IOSMicrobenchOperationResult] = []
                for operation in BenchOperation.allCases {
                    var batchStats: [IOSMicrobenchBatchStats] = []
                    var pooledSamples: [Double] = []
                    for batch in 1...batches {
                        progressText = "[\(suite.suiteLabel)] \(operation.displayName) batch \(batch)/\(batches)"
                        let samples: [Double]
                        switch operation {
                        case .kemEncapsulate:
                            samples = try await measureSamples(warmup: warmup, iterations: iterations) {
                                _ = try await runtime.provider.kemEncapsulate(recipientPublicKey: runtime.kemPublicKey)
                            }
                        case .sign:
                            samples = try await measureSamples(warmup: warmup, iterations: iterations) {
                                _ = try await runtime.provider.sign(data: payload, using: .softwareKey(runtime.sigPrivateKey))
                            }
                        case .verify:
                            samples = try await measureSamples(warmup: warmup, iterations: iterations) {
                                _ = try await runtime.provider.verify(
                                    data: payload,
                                    signature: verifySignature,
                                    publicKey: runtime.sigPublicKey
                                )
                            }
                        case .sealOpen:
                            samples = try await measureSamples(warmup: warmup, iterations: iterations) {
                                let sealed = try await runtime.provider.hpkeSeal(
                                    plaintext: payload,
                                    recipientPublicKey: runtime.kemPublicKey,
                                    info: hpkeInfo
                                )
                                _ = try await runtime.provider.hpkeOpen(
                                    sealedBox: sealed,
                                    privateKey: runtime.kemPrivateKey,
                                    info: hpkeInfo
                                )
                            }
                        }

                        pooledSamples.append(contentsOf: samples)
                        batchStats.append(
                            IOSMicrobenchBatchStats(
                                batch: batch,
                                warmup: warmup,
                                iterations: iterations,
                                meanMs: mean(samples),
                                p50Ms: percentile(samples, 0.50),
                                p95Ms: percentile(samples, 0.95),
                                p99Ms: percentile(samples, 0.99),
                                stdMs: stddev(samples)
                            )
                        )
                        completedOps += 1
                        progressText = "进度 \(completedOps)/\(totalOps)"
                    }

                    operationResults.append(
                        IOSMicrobenchOperationResult(
                            operation: operation.rawValue,
                            batches: batchStats,
                            summary: IOSMicrobenchSummaryStats(
                                samples: pooledSamples.count,
                                batchesObserved: batchStats.count,
                                meanMs: mean(pooledSamples),
                                p50Ms: percentile(pooledSamples, 0.50),
                                p95Ms: percentile(pooledSamples, 0.95),
                                p99Ms: percentile(pooledSamples, 0.99),
                                stdMs: stddev(pooledSamples)
                            )
                        )
                    )
                }

                suiteResults.append(
                    IOSMicrobenchSuiteResult(
                        suiteId: suite.suiteId,
                        suiteLabel: suite.suiteLabel,
                        kemSuite: suite.kemSuite,
                        sigSuite: suite.sigSuite,
                        status: "ok",
                        note: nil,
                        operations: operationResults
                    )
                )
            }

            let artifact = IOSMicrobenchArtifactV3(
                schemaVersion: 3,
                artifactDate: stamp,
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                device: currentDeviceMetadata(label: label),
                runConfig: IOSMicrobenchRunConfig(warmup: warmup, iterations: iterations, batches: batches),
                suites: suiteResults
            )

            let outURL = try writeArtifact(artifact: artifact, artifactDate: stamp, deviceLabel: label)
            artifactURL = outURL
            progressText = "完成: \(outURL.lastPathComponent)"
        } catch {
            errorText = "benchmark failed: \(error.localizedDescription)"
        }
    }

    private func buildSuiteRuntimes() async throws -> [SuiteRuntimeRecord] {
        var out: [SuiteRuntimeRecord] = []

        let classicProvider = ClassicCryptoProvider()
        out.append(try await buildRuntimeRecord(
            suiteId: "classic_x25519_ed25519",
            suiteLabel: "Classic (X25519 + Ed25519)",
            kemSuite: "X25519",
            sigSuite: "Ed25519",
            provider: classicProvider
        ))

        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, *) {
            let pqcProvider = ApplePQCCryptoProvider()
            out.append(try await buildRuntimeRecord(
                suiteId: "cryptokit_mlkem768_mldsa65",
                suiteLabel: "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)",
                kemSuite: "ML-KEM-768",
                sigSuite: "ML-DSA-65",
                provider: pqcProvider
            ))

            let xwingProvider = AppleXWingCryptoProvider()
            out.append(try await buildRuntimeRecord(
                suiteId: "cryptokit_xwing_mldsa65",
                suiteLabel: "CryptoKit Hybrid (X-Wing + ML-DSA-65)",
                kemSuite: "X-Wing",
                sigSuite: "ML-DSA-65",
                provider: xwingProvider
            ))
        } else {
            out.append(SuiteRuntimeRecord.unavailable(
                suiteId: "cryptokit_mlkem768_mldsa65",
                suiteLabel: "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)",
                kemSuite: "ML-KEM-768",
                sigSuite: "ML-DSA-65",
                reason: "requires iOS 26+"
            ))
            out.append(SuiteRuntimeRecord.unavailable(
                suiteId: "cryptokit_xwing_mldsa65",
                suiteLabel: "CryptoKit Hybrid (X-Wing + ML-DSA-65)",
                kemSuite: "X-Wing",
                sigSuite: "ML-DSA-65",
                reason: "requires iOS 26+"
            ))
        }
        #else
        out.append(SuiteRuntimeRecord.unavailable(
            suiteId: "cryptokit_mlkem768_mldsa65",
            suiteLabel: "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)",
            kemSuite: "ML-KEM-768",
            sigSuite: "ML-DSA-65",
            reason: "build without HAS_APPLE_PQC_SDK"
        ))
        out.append(SuiteRuntimeRecord.unavailable(
            suiteId: "cryptokit_xwing_mldsa65",
            suiteLabel: "CryptoKit Hybrid (X-Wing + ML-DSA-65)",
            kemSuite: "X-Wing",
            sigSuite: "ML-DSA-65",
            reason: "build without HAS_APPLE_PQC_SDK"
        ))
        #endif

        return out
    }

    private func buildRuntimeRecord(
        suiteId: String,
        suiteLabel: String,
        kemSuite: String,
        sigSuite: String,
        provider: any CryptoProvider
    ) async throws -> SuiteRuntimeRecord {
        let kem = try await provider.generateKeyPair(for: .keyExchange)
        let sig = try await provider.generateKeyPair(for: .signing)
        let runtime = SuiteRuntime(
            provider: provider,
            kemPublicKey: kem.publicKey.bytes,
            kemPrivateKey: kem.privateKey.bytes,
            sigPublicKey: sig.publicKey.bytes,
            sigPrivateKey: sig.privateKey.bytes
        )
        return SuiteRuntimeRecord(
            suiteId: suiteId,
            suiteLabel: suiteLabel,
            kemSuite: kemSuite,
            sigSuite: sigSuite,
            runtime: runtime,
            unavailableReason: nil
        )
    }

    private func measureSamples(
        warmup: Int,
        iterations: Int,
        operation: @escaping () async throws -> Void
    ) async throws -> [Double] {
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(iterations)

        for index in 0..<(warmup + iterations) {
            let start = clock.now
            try await operation()
            let elapsed = clock.now - start
            if index >= warmup {
                let ms = Double(elapsed.components.seconds) * 1_000.0 +
                    Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
                samples.append(ms)
            }
        }
        return samples
    }

    private func writeArtifact(
        artifact: IOSMicrobenchArtifactV3,
        artifactDate: String,
        deviceLabel: String
    ) throws -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("ios_microbench_\(artifactDate)_\(deviceLabel).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(artifact)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func sanitize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "run" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(mapped.prefix(64))
    }

    private func currentDeviceMetadata(label: String) -> IOSMicrobenchDeviceMetadata {
        IOSMicrobenchDeviceMetadata(
            deviceLabel: label,
            model: UIDevice.current.model,
            machine: Self.machineIdentifier(),
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            osBuild: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: Self.machineIdentifier(),
            thermalState: Self.thermalStateString(ProcessInfo.processInfo.thermalState)
        )
    }

    private static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let chars = mirror.children.compactMap { element -> UInt8? in
            guard let value = element.value as? Int8, value != 0 else { return nil }
            return UInt8(value)
        }
        return String(decoding: chars, as: UTF8.self)
    }

    private static func defaultDeviceLabel() -> String {
        let machine = machineIdentifier().lowercased().replacingOccurrences(of: ",", with: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = machine.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(mapped.prefix(32))
    }

    private func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0.0 }
        return xs.reduce(0, +) / Double(xs.count)
    }

    private func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0.0 }
        let sorted = xs.sorted()
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    private func stddev(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0.0 }
        let avg = mean(xs)
        let variance = xs.reduce(0.0) { acc, item in
            let delta = item - avg
            return acc + delta * delta
        } / Double(xs.count - 1)
        return sqrt(variance)
    }
}

private enum BenchOperation: String, CaseIterable {
    case kemEncapsulate = "kem_encapsulate"
    case sign = "sign"
    case verify = "verify"
    case sealOpen = "kem_dem_seal_open"

    var displayName: String {
        switch self {
        case .kemEncapsulate: return "KEM encapsulate"
        case .sign: return "Sign"
        case .verify: return "Verify"
        case .sealOpen: return "KEM-DEM seal+open"
        }
    }
}

private struct SuiteRuntimeRecord {
    let suiteId: String
    let suiteLabel: String
    let kemSuite: String
    let sigSuite: String
    let runtime: SuiteRuntime?
    let unavailableReason: String?

    static func unavailable(
        suiteId: String,
        suiteLabel: String,
        kemSuite: String,
        sigSuite: String,
        reason: String
    ) -> SuiteRuntimeRecord {
        SuiteRuntimeRecord(
            suiteId: suiteId,
            suiteLabel: suiteLabel,
            kemSuite: kemSuite,
            sigSuite: sigSuite,
            runtime: nil,
            unavailableReason: reason
        )
    }
}

private struct SuiteRuntime {
    let provider: any CryptoProvider
    let kemPublicKey: Data
    let kemPrivateKey: Data
    let sigPublicKey: Data
    let sigPrivateKey: Data
}

private struct IOSMicrobenchArtifactV3: Codable {
    let schemaVersion: Int
    let artifactDate: String
    let generatedAt: String
    let device: IOSMicrobenchDeviceMetadata
    let runConfig: IOSMicrobenchRunConfig
    let suites: [IOSMicrobenchSuiteResult]
}

private struct IOSMicrobenchDeviceMetadata: Codable {
    let deviceLabel: String
    let model: String
    let machine: String
    let systemName: String
    let systemVersion: String
    let osBuild: String
    let chip: String
    let thermalState: String
}

private struct IOSMicrobenchRunConfig: Codable {
    let warmup: Int
    let iterations: Int
    let batches: Int
}

private struct IOSMicrobenchSuiteResult: Codable {
    let suiteId: String
    let suiteLabel: String
    let kemSuite: String
    let sigSuite: String
    let status: String
    let note: String?
    let operations: [IOSMicrobenchOperationResult]
}

private struct IOSMicrobenchOperationResult: Codable {
    let operation: String
    let batches: [IOSMicrobenchBatchStats]
    let summary: IOSMicrobenchSummaryStats
}

private struct IOSMicrobenchBatchStats: Codable {
    let batch: Int
    let warmup: Int
    let iterations: Int
    let meanMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let stdMs: Double
}

private struct IOSMicrobenchSummaryStats: Codable {
    let samples: Int
    let batchesObserved: Int
    let meanMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let stdMs: Double
}
