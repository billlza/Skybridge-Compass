import Darwin
import Foundation
import Security
import PrivateSensorBridge

private let sharedPowerMetricsProvider = PowerMetricsProvider()

// Helper 入口：配置 XPC 监听并运行（使用顶层启动）
let helperDelegate = XPCDelegate(provider: sharedPowerMetricsProvider)
let helperListener = NSXPCListener(machServiceName: "com.skybridge.PowerMetricsHelper")
helperListener.delegate = helperDelegate
helperListener.resume()
RunLoop.current.run()

final class XPCDelegate: NSObject, NSXPCListenerDelegate {
    private let provider: PowerMetricsProvider

    init(provider: PowerMetricsProvider) {
        self.provider = provider
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let allowedIdentifier = "com.skybridge.compass.pro"
        guard verifyConnectionIdentifier(newConnection, allowedIdentifier: allowedIdentifier) else {
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: PowerMetricsXPCProtocol.self)
        newConnection.exportedObject = provider
        newConnection.resume()
        return true
    }
}

private func verifyConnectionIdentifier(_ connection: NSXPCConnection, allowedIdentifier: String) -> Bool {
    let pid = connection.processIdentifier
    var guest: SecCode?
    let attrs: [CFString: Any] = [kSecGuestAttributePid: pid]
    let statusGuest = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, SecCSFlags(), &guest)
    guard statusGuest == errSecSuccess, let guest else { return false }
    var requirement: SecRequirement?
    let reqString = "identifier \"\(allowedIdentifier)\""
    let statusReq = SecRequirementCreateWithString(reqString as CFString, SecCSFlags(), &requirement)
    guard statusReq == errSecSuccess, let requirement else { return false }
    let statusValid = SecCodeCheckValidity(guest, SecCSFlags(), requirement)
    return statusValid == errSecSuccess
}

@objc protocol PowerMetricsXPCProtocol {
    func fetchSnapshot(completion: @Sendable @escaping (Data?) -> Void)
    func fetchServiceInfo(completion: @Sendable @escaping (Data?) -> Void)
}

final class PowerMetricsProvider: NSObject, PowerMetricsXPCProtocol, @unchecked Sendable {
    private static let helperVersion = "2.4.0"
    private static let helperVersionMarker = "SKYBRIDGE_HELPER_VERSION=2.4.0"
    private static let protocolVersion = 3

    private enum MonitoringMode: String, Codable {
        case standardPublic
        case expertPrivate
    }

    private enum MetricAvailability: String, Codable {
        case available
        case unavailable
        case stale
    }

    private enum MetricUnavailableReason: String, Codable {
        case unsupported
        case permissionDenied
        case notProvidedByOS
        case helperUnavailable
        case helperOutdated
        case parsingFailed
        case sampling
        case requiresExpertMode
        case temporarilyInitializing
    }

    private enum MetricSource: String, Codable {
        case kernelAPI
        case ioAccelerator
        case smc
        case iohid
        case ioreport
        case powermetrics
        case processInfoThermalState
    }

    private struct MetricState: Codable {
        let availability: MetricAvailability
        let reason: MetricUnavailableReason?
        let source: MetricSource?
        let sampledAt: Date?

        static func available(source: MetricSource, sampledAt: Date) -> MetricState {
            MetricState(availability: .available, reason: nil, source: source, sampledAt: sampledAt)
        }

        static func unavailable(reason: MetricUnavailableReason, source: MetricSource?, sampledAt: Date?) -> MetricState {
            MetricState(availability: .unavailable, reason: reason, source: source, sampledAt: sampledAt)
        }

        static func stale(source: MetricSource?, sampledAt: Date?) -> MetricState {
            MetricState(availability: .stale, reason: nil, source: source, sampledAt: sampledAt)
        }

        func ageMs(at now: Date) -> Int? {
            guard let sampledAt else { return nil }
            let age = max(0, now.timeIntervalSince(sampledAt))
            return Int((age * 1000.0).rounded())
        }
    }

    private struct ServiceInfo: Codable {
        let protocolVersion: Int
        let helperVersion: String
        let helperStartedAt: Date
    }

    private enum TemperatureGroup: String, Codable {
        case cpu
        case gpu
        case memory
        case system
        case unknown
    }

    private struct TemperatureReading: Codable {
        let key: String
        let group: TemperatureGroup
        let source: MetricSource?
        let valueCelsius: Double
    }

    private struct FanReading: Codable {
        let index: Int
        let key: String
        let rpm: Int
        let source: MetricSource?
    }

    private enum PowerComponent: String, Codable {
        case cpu
        case gpu
        case ane
        case ram
        case package
        case unknown
    }

    private struct PowerReading: Codable {
        let component: PowerComponent
        let source: MetricSource?
        let watts: Double
    }

    private struct Snapshot: Codable {
        let timestamp: Date
        let monitoringMode: MonitoringMode?
        let cpuUsagePercent: Double?
        let memoryUsagePercent: Double?
        let gpuUsagePercent: Double?
        let cpuPowerWatts: Double?
        let gpuPowerWatts: Double?
        let anePowerWatts: Double?
        let ramPowerWatts: Double?
        let packagePowerWatts: Double?
        let cpuTemperatureC: Double?
        let gpuTemperatureC: Double?
        let fanRPMs: [Int]?
        let loadAvg1: Double?
        let loadAvg5: Double?
        let loadAvg15: Double?

        let gpuUsageState: MetricState?
        let gpuPowerState: MetricState?
        let cpuTemperatureState: MetricState?
        let gpuTemperatureState: MetricState?
        let fanState: MetricState?

        let protocolVersion: Int?
        let helperVersion: String?
        let helperStartedAt: Date?

        let gpuUsageAgeMs: Int?
        let gpuPowerAgeMs: Int?
        let cpuTemperatureAgeMs: Int?
        let gpuTemperatureAgeMs: Int?
        let fanAgeMs: Int?

        let temperatureReadings: [TemperatureReading]?
        let fanReadings: [FanReading]?
        let cpuTemperatureHottestC: Double?
        let gpuTemperatureHottestC: Double?
        let cpuTemperatureAverageC: Double?
        let gpuTemperatureAverageC: Double?
        let powerReadings: [PowerReading]?

        static func bootstrap(now: Date) -> Snapshot {
            Snapshot(
                timestamp: now,
                monitoringMode: .expertPrivate,
                cpuUsagePercent: nil,
                memoryUsagePercent: nil,
                gpuUsagePercent: nil,
                cpuPowerWatts: nil,
                gpuPowerWatts: nil,
                anePowerWatts: nil,
                ramPowerWatts: nil,
                packagePowerWatts: nil,
                cpuTemperatureC: nil,
                gpuTemperatureC: nil,
                fanRPMs: nil,
                loadAvg1: nil,
                loadAvg5: nil,
                loadAvg15: nil,
                gpuUsageState: .unavailable(reason: .temporarilyInitializing, source: .powermetrics, sampledAt: now),
                gpuPowerState: .unavailable(reason: .temporarilyInitializing, source: .powermetrics, sampledAt: now),
                cpuTemperatureState: .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: now),
                gpuTemperatureState: .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: now),
                fanState: .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: now),
                protocolVersion: PowerMetricsProvider.protocolVersion,
                helperVersion: PowerMetricsProvider.helperVersion,
                helperStartedAt: now,
                gpuUsageAgeMs: 0,
                gpuPowerAgeMs: 0,
                cpuTemperatureAgeMs: 0,
                gpuTemperatureAgeMs: 0,
                fanAgeMs: 0,
                temperatureReadings: nil,
                fanReadings: nil,
                cpuTemperatureHottestC: nil,
                gpuTemperatureHottestC: nil,
                cpuTemperatureAverageC: nil,
                gpuTemperatureAverageC: nil,
                powerReadings: nil
            )
        }
    }

    private struct ParsedValueSet {
        var gpuUsagePercent: Double?
        var cpuPowerWatts: Double?
        var gpuPowerWatts: Double?
        var anePowerWatts: Double?
        var ramPowerWatts: Double?
        var packagePowerWatts: Double?
        var cpuTemperatureC: Double?
        var gpuTemperatureC: Double?
        var fanRPMs: [Int]?
        var temperatureReadings: [TemperatureReading]?
        var fanReadings: [FanReading]?
        var cpuTemperatureHottestC: Double?
        var gpuTemperatureHottestC: Double?
        var cpuTemperatureAverageC: Double?
        var gpuTemperatureAverageC: Double?
        var powerReadings: [PowerReading]?
    }

    private struct ParsedPowerMetrics {
        let sampledAt: Date
        let values: ParsedValueSet
        let gpuUsageState: MetricState
        let gpuPowerState: MetricState
        let cpuTemperatureState: MetricState
        let gpuTemperatureState: MetricState
        let fanState: MetricState
    }

    private struct PowermetricsExecution {
        let stdoutData: Data
        let stderrData: Data
        let status: Int32

        var stdout: String { String(data: stdoutData, encoding: .utf8) ?? "" }
        var stderr: String { String(data: stderrData, encoding: .utf8) ?? "" }
        var merged: String { stdout + "\n" + stderr }
    }

    private let queue = DispatchQueue(label: "com.skybridge.PowerMetricsHelper.provider")
    private let sampleIntervalSeconds: TimeInterval = 1.0
    private let powermetricsIntervalSeconds: TimeInterval = 2.0
    private let staleThresholdSeconds: TimeInterval = 3.5
    private let binaryCheckIntervalSeconds: TimeInterval = 20.0

    private var latestSnapshot: Snapshot
    private var lastPowermetricsSampleAt: Date = .distantPast
    private var lastBinaryCheckAt: Date = .distantPast
    private var lastDiagnosticSignature: String = ""
    private let helperStartedAt: Date
    private let helperBinaryPath: String?
    private let privateSensorBridge = PrivateSensorBridge.shared

    private var samplerTimer: DispatchSourceTimer?

    private let plistArguments: [[String]] = [
        ["-n", "1", "-i", "1000", "--samplers", "cpu_power,gpu_power,thermal", "--format", "plist", "--show-extra-power-info"],
        ["-n", "1", "-i", "1000", "--samplers", "cpu_power,gpu_power,thermal", "--format", "plist"],
        ["-n", "1", "-i", "1000", "--samplers", "cpu_power,gpu_power", "--format", "plist"]
    ]

    private let textArguments: [[String]] = [
        ["-n", "1", "-i", "1000", "--samplers", "cpu_power,gpu_power,thermal", "--show-extra-power-info"],
        ["-n", "1", "-i", "1000", "--samplers", "cpu_power,gpu_power,thermal"],
        ["-n", "1", "-i", "1000", "--samplers", "cpu_power,gpu_power"]
    ]

    override init() {
        let now = Date()
        self.helperStartedAt = now
        self.helperBinaryPath = CommandLine.arguments.first
        self.latestSnapshot = Snapshot.bootstrap(now: now)
        NSLog("[PowerMetricsHelper] \(Self.helperVersionMarker)")
        super.init()
        startSamplingLoop()
    }

    deinit {
        samplerTimer?.cancel()
    }

    func fetchSnapshot(completion: @Sendable @escaping (Data?) -> Void) {
        queue.async { [weak self] in
            guard let self else { completion(nil); return }
            let snapshot = self.snapshotForDelivery(at: Date())
            completion(try? JSONEncoder().encode(snapshot))
        }
    }

    func fetchServiceInfo(completion: @Sendable @escaping (Data?) -> Void) {
        queue.async { [weak self] in
            guard let self else { completion(nil); return }
            let info = ServiceInfo(
                protocolVersion: Self.protocolVersion,
                helperVersion: Self.helperVersion,
                helperStartedAt: self.helperStartedAt
            )
            completion(try? JSONEncoder().encode(info))
        }
    }

    private func startSamplingLoop() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.samplerTimer == nil else { return }

            self.sampleOnce()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.sampleIntervalSeconds, repeating: self.sampleIntervalSeconds)
            timer.setEventHandler { [weak self] in
                self?.sampleOnce()
            }
            self.samplerTimer = timer
            timer.resume()
        }
    }

    private func sampleOnce() {
        let now = Date()
        checkForUpdatedBinaryIfNeeded(now: now)

        let parsedFromPowerMetrics: ParsedPowerMetrics
        if now.timeIntervalSince(lastPowermetricsSampleAt) >= powermetricsIntervalSeconds {
            parsedFromPowerMetrics = readPowerMetrics(sampledAt: now)
            lastPowermetricsSampleAt = now
        } else {
            parsedFromPowerMetrics = parsedFromSnapshot(latestSnapshot, now: now)
        }

        let privateSensors = privateSensorBridge.sample()
        let parsed = mergePrivateSensors(
            parsedFromPowerMetrics,
            privateSensors: privateSensors,
            sampledAt: now
        )

        let loadAverages = readLoadAverages()
        let memoryUsage = readMemoryUsagePercent()

        latestSnapshot = makeSnapshot(
            sampledAt: now,
            memoryUsage: memoryUsage,
            loadAverages: loadAverages,
            parsed: parsed
        )

        logSnapshotReasonIfNeeded(latestSnapshot)
    }

    private func parsedFromSnapshot(_ snapshot: Snapshot, now: Date) -> ParsedPowerMetrics {
        let sampledAt = snapshot.timestamp
        return ParsedPowerMetrics(
            sampledAt: sampledAt,
            values: ParsedValueSet(
                gpuUsagePercent: snapshot.gpuUsagePercent,
                cpuPowerWatts: snapshot.cpuPowerWatts,
                gpuPowerWatts: snapshot.gpuPowerWatts,
                anePowerWatts: snapshot.anePowerWatts,
                ramPowerWatts: snapshot.ramPowerWatts,
                packagePowerWatts: snapshot.packagePowerWatts,
                cpuTemperatureC: snapshot.cpuTemperatureC,
                gpuTemperatureC: snapshot.gpuTemperatureC,
                fanRPMs: snapshot.fanRPMs,
                temperatureReadings: snapshot.temperatureReadings,
                fanReadings: snapshot.fanReadings,
                cpuTemperatureHottestC: snapshot.cpuTemperatureHottestC,
                gpuTemperatureHottestC: snapshot.gpuTemperatureHottestC,
                cpuTemperatureAverageC: snapshot.cpuTemperatureAverageC,
                gpuTemperatureAverageC: snapshot.gpuTemperatureAverageC,
                powerReadings: snapshot.powerReadings
            ),
            gpuUsageState: snapshot.gpuUsageState ?? .unavailable(reason: .temporarilyInitializing, source: .powermetrics, sampledAt: sampledAt),
            gpuPowerState: snapshot.gpuPowerState ?? .unavailable(reason: .temporarilyInitializing, source: .powermetrics, sampledAt: sampledAt),
            cpuTemperatureState: snapshot.cpuTemperatureState ?? .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: sampledAt),
            gpuTemperatureState: snapshot.gpuTemperatureState ?? .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: sampledAt),
            fanState: snapshot.fanState ?? .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: sampledAt)
        )
    }

    private func makeSnapshot(
        sampledAt: Date,
        memoryUsage: Double?,
        loadAverages: (Double?, Double?, Double?),
        parsed: ParsedPowerMetrics
    ) -> Snapshot {
        let gpuUsageAge = parsed.gpuUsageState.ageMs(at: sampledAt)
        let gpuPowerAge = parsed.gpuPowerState.ageMs(at: sampledAt)
        let cpuTempAge = parsed.cpuTemperatureState.ageMs(at: sampledAt)
        let gpuTempAge = parsed.gpuTemperatureState.ageMs(at: sampledAt)
        let fanAge = parsed.fanState.ageMs(at: sampledAt)

        return Snapshot(
            timestamp: sampledAt,
            monitoringMode: .expertPrivate,
            cpuUsagePercent: nil,
            memoryUsagePercent: memoryUsage,
            gpuUsagePercent: parsed.values.gpuUsagePercent,
            cpuPowerWatts: parsed.values.cpuPowerWatts,
            gpuPowerWatts: parsed.values.gpuPowerWatts,
            anePowerWatts: parsed.values.anePowerWatts,
            ramPowerWatts: parsed.values.ramPowerWatts,
            packagePowerWatts: parsed.values.packagePowerWatts,
            cpuTemperatureC: parsed.values.cpuTemperatureC,
            gpuTemperatureC: parsed.values.gpuTemperatureC,
            fanRPMs: parsed.values.fanRPMs,
            loadAvg1: loadAverages.0,
            loadAvg5: loadAverages.1,
            loadAvg15: loadAverages.2,
            gpuUsageState: parsed.gpuUsageState,
            gpuPowerState: parsed.gpuPowerState,
            cpuTemperatureState: parsed.cpuTemperatureState,
            gpuTemperatureState: parsed.gpuTemperatureState,
            fanState: parsed.fanState,
            protocolVersion: Self.protocolVersion,
            helperVersion: Self.helperVersion,
            helperStartedAt: helperStartedAt,
            gpuUsageAgeMs: gpuUsageAge,
            gpuPowerAgeMs: gpuPowerAge,
            cpuTemperatureAgeMs: cpuTempAge,
            gpuTemperatureAgeMs: gpuTempAge,
            fanAgeMs: fanAge,
            temperatureReadings: parsed.values.temperatureReadings,
            fanReadings: parsed.values.fanReadings,
            cpuTemperatureHottestC: parsed.values.cpuTemperatureHottestC,
            gpuTemperatureHottestC: parsed.values.gpuTemperatureHottestC,
            cpuTemperatureAverageC: parsed.values.cpuTemperatureAverageC,
            gpuTemperatureAverageC: parsed.values.gpuTemperatureAverageC,
            powerReadings: parsed.values.powerReadings
        )
    }

    private func snapshotForDelivery(at now: Date) -> Snapshot {
        let age = now.timeIntervalSince(latestSnapshot.timestamp)
        guard age > staleThresholdSeconds else { return latestSnapshot }

        return Snapshot(
            timestamp: latestSnapshot.timestamp,
            monitoringMode: latestSnapshot.monitoringMode,
            cpuUsagePercent: latestSnapshot.cpuUsagePercent,
            memoryUsagePercent: latestSnapshot.memoryUsagePercent,
            gpuUsagePercent: latestSnapshot.gpuUsagePercent,
            cpuPowerWatts: latestSnapshot.cpuPowerWatts,
            gpuPowerWatts: latestSnapshot.gpuPowerWatts,
            anePowerWatts: latestSnapshot.anePowerWatts,
            ramPowerWatts: latestSnapshot.ramPowerWatts,
            packagePowerWatts: latestSnapshot.packagePowerWatts,
            cpuTemperatureC: latestSnapshot.cpuTemperatureC,
            gpuTemperatureC: latestSnapshot.gpuTemperatureC,
            fanRPMs: latestSnapshot.fanRPMs,
            loadAvg1: latestSnapshot.loadAvg1,
            loadAvg5: latestSnapshot.loadAvg5,
            loadAvg15: latestSnapshot.loadAvg15,
            gpuUsageState: staleState(from: latestSnapshot.gpuUsageState),
            gpuPowerState: staleState(from: latestSnapshot.gpuPowerState),
            cpuTemperatureState: staleState(from: latestSnapshot.cpuTemperatureState),
            gpuTemperatureState: staleState(from: latestSnapshot.gpuTemperatureState),
            fanState: staleState(from: latestSnapshot.fanState),
            protocolVersion: latestSnapshot.protocolVersion,
            helperVersion: latestSnapshot.helperVersion,
            helperStartedAt: latestSnapshot.helperStartedAt,
            gpuUsageAgeMs: latestSnapshot.gpuUsageState?.ageMs(at: now),
            gpuPowerAgeMs: latestSnapshot.gpuPowerState?.ageMs(at: now),
            cpuTemperatureAgeMs: latestSnapshot.cpuTemperatureState?.ageMs(at: now),
            gpuTemperatureAgeMs: latestSnapshot.gpuTemperatureState?.ageMs(at: now),
            fanAgeMs: latestSnapshot.fanState?.ageMs(at: now),
            temperatureReadings: latestSnapshot.temperatureReadings,
            fanReadings: latestSnapshot.fanReadings,
            cpuTemperatureHottestC: latestSnapshot.cpuTemperatureHottestC,
            gpuTemperatureHottestC: latestSnapshot.gpuTemperatureHottestC,
            cpuTemperatureAverageC: latestSnapshot.cpuTemperatureAverageC,
            gpuTemperatureAverageC: latestSnapshot.gpuTemperatureAverageC,
            powerReadings: latestSnapshot.powerReadings
        )
    }

    private func staleState(from state: MetricState?) -> MetricState? {
        guard let state else { return nil }
        guard state.availability == .available else { return state }
        return .stale(source: state.source, sampledAt: state.sampledAt)
    }

    private func mergePrivateSensors(
        _ powermetrics: ParsedPowerMetrics,
        privateSensors: PrivateSensorSnapshot,
        sampledAt: Date
    ) -> ParsedPowerMetrics {
        let sensorMissingReason: MetricUnavailableReason = switch privateSensors.status {
        case .available:
            .notProvidedByOS
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .unsupported
        }

        var mergedValues = powermetrics.values
        var cpuTempState = powermetrics.cpuTemperatureState
        var gpuTempState = powermetrics.gpuTemperatureState
        var fanState = powermetrics.fanState
        var gpuPowerState = powermetrics.gpuPowerState

        let temperatureReadings = privateSensors.temperatureReadings.map(mapTemperatureReading)
        if !temperatureReadings.isEmpty {
            mergedValues.temperatureReadings = temperatureReadings
        }

        let fanReadings = privateSensors.fanReadings.map(mapFanReading)
        if !fanReadings.isEmpty {
            mergedValues.fanReadings = fanReadings
        }

        if let cpuTemperature = privateSensors.cpuTemperatureC {
            mergedValues.cpuTemperatureC = cpuTemperature
            let source: MetricSource = privateSensors.cpuTemperatureFromHID ? .iohid : .smc
            mergedValues.cpuTemperatureHottestC = cpuTemperature
            mergedValues.cpuTemperatureAverageC = averageTemperature(
                temperatureReadings,
                group: .cpu,
                source: source
            ) ?? cpuTemperature
            cpuTempState = .available(source: source, sampledAt: sampledAt)
        } else if cpuTempState.availability != .available {
            cpuTempState = .unavailable(reason: sensorMissingReason, source: .smc, sampledAt: sampledAt)
        }

        if let gpuTemperature = privateSensors.gpuTemperatureC {
            mergedValues.gpuTemperatureC = gpuTemperature
            let source: MetricSource = privateSensors.gpuTemperatureFromHID ? .iohid : .smc
            mergedValues.gpuTemperatureHottestC = gpuTemperature
            mergedValues.gpuTemperatureAverageC = averageTemperature(
                temperatureReadings,
                group: .gpu,
                source: source
            ) ?? gpuTemperature
            gpuTempState = .available(source: source, sampledAt: sampledAt)
        } else if gpuTempState.availability != .available {
            gpuTempState = .unavailable(reason: sensorMissingReason, source: .smc, sampledAt: sampledAt)
        }

        if !privateSensors.fanRPMs.isEmpty {
            mergedValues.fanRPMs = privateSensors.fanRPMs
            fanState = .available(source: .smc, sampledAt: sampledAt)
        } else if fanState.availability != .available {
            fanState = .unavailable(reason: sensorMissingReason, source: .smc, sampledAt: sampledAt)
        }

        let powerReadings = privateSensors.powerReadings.map(mapPowerReading)
        if !powerReadings.isEmpty {
            mergedValues.powerReadings = powerReadings
        }
        if let cpuPowerWatts = privateSensors.cpuPowerWatts {
            mergedValues.cpuPowerWatts = cpuPowerWatts
        }
        if let gpuPowerWatts = privateSensors.gpuPowerWatts {
            mergedValues.gpuPowerWatts = gpuPowerWatts
            gpuPowerState = .available(source: .ioreport, sampledAt: sampledAt)
        }
        if let anePowerWatts = privateSensors.anePowerWatts {
            mergedValues.anePowerWatts = anePowerWatts
        }
        if let ramPowerWatts = privateSensors.ramPowerWatts {
            mergedValues.ramPowerWatts = ramPowerWatts
        }
        if let packagePowerWatts = privateSensors.packagePowerWatts {
            mergedValues.packagePowerWatts = packagePowerWatts
        }
        if privateSensors.gpuPowerWatts == nil, gpuPowerState.availability == .unavailable {
            gpuPowerState = .unavailable(reason: sensorMissingReason, source: .ioreport, sampledAt: sampledAt)
        }

        return ParsedPowerMetrics(
            sampledAt: sampledAt,
            values: mergedValues,
            gpuUsageState: powermetrics.gpuUsageState,
            gpuPowerState: gpuPowerState,
            cpuTemperatureState: cpuTempState,
            gpuTemperatureState: gpuTempState,
            fanState: fanState
        )
    }

    private func mapTemperatureReading(_ reading: PrivateTemperatureReading) -> TemperatureReading {
        TemperatureReading(
            key: reading.key,
            group: mapTemperatureGroup(reading.group),
            source: mapSensorSource(reading.source),
            valueCelsius: reading.valueCelsius
        )
    }

    private func mapFanReading(_ reading: PrivateFanReading) -> FanReading {
        FanReading(
            index: reading.index,
            key: reading.key,
            rpm: reading.rpm,
            source: mapSensorSource(reading.source)
        )
    }

    private func mapPowerReading(_ reading: PrivatePowerReading) -> PowerReading {
        PowerReading(
            component: mapPowerComponent(reading.component),
            source: mapSensorSource(reading.source),
            watts: reading.watts
        )
    }

    private func mapTemperatureGroup(_ group: PrivateTemperatureSensorGroup) -> TemperatureGroup {
        switch group {
        case .cpu:
            return .cpu
        case .gpu:
            return .gpu
        case .memory:
            return .memory
        case .system:
            return .system
        case .unknown:
            return .unknown
        }
    }

    private func mapPowerComponent(_ component: PrivatePowerComponent) -> PowerComponent {
        switch component {
        case .cpu:
            return .cpu
        case .gpu:
            return .gpu
        case .ane:
            return .ane
        case .ram:
            return .ram
        case .package:
            return .package
        case .unknown:
            return .unknown
        }
    }

    private func mapSensorSource(_ source: PrivateSensorSource) -> MetricSource {
        switch source {
        case .smc:
            return .smc
        case .iohid:
            return .iohid
        case .ioreport:
            return .ioreport
        }
    }

    private func averageTemperature(
        _ readings: [TemperatureReading],
        group: TemperatureGroup,
        source: MetricSource
    ) -> Double? {
        let values = readings
            .filter { $0.group == group && $0.source == source }
            .map(\.valueCelsius)
            .filter { $0.isFinite && $0 >= -10 && $0 <= 130 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func buildParsedMetrics(
        sampledAt: Date,
        values: ParsedValueSet,
        missingReason: MetricUnavailableReason
    ) -> ParsedPowerMetrics {
        func stateForValue(_ value: Double?) -> MetricState {
            if value != nil {
                return .available(source: .powermetrics, sampledAt: sampledAt)
            }
            return .unavailable(reason: missingReason, source: .powermetrics, sampledAt: sampledAt)
        }

        let fanState: MetricState
        if let fans = values.fanRPMs, !fans.isEmpty {
            fanState = .available(source: .powermetrics, sampledAt: sampledAt)
        } else {
            fanState = .unavailable(reason: missingReason, source: .powermetrics, sampledAt: sampledAt)
        }

        return ParsedPowerMetrics(
            sampledAt: sampledAt,
            values: values,
            gpuUsageState: stateForValue(values.gpuUsagePercent),
            gpuPowerState: stateForValue(values.gpuPowerWatts),
            cpuTemperatureState: stateForValue(values.cpuTemperatureC),
            gpuTemperatureState: stateForValue(values.gpuTemperatureC),
            fanState: fanState
        )
    }

    private func readPowerMetrics(sampledAt: Date) -> ParsedPowerMetrics {
        var sawUnsupported = false
        var sawSuccess = false
        var lastReason: MetricUnavailableReason = .parsingFailed
        var lastOutput = ""

        for args in plistArguments {
            guard let execution = runPowerMetrics(arguments: args) else { continue }
            if !execution.merged.isEmpty { lastOutput = execution.merged }

            if containsPermissionDenied(execution.merged) {
                return buildParsedMetrics(sampledAt: sampledAt, values: ParsedValueSet(), missingReason: .permissionDenied)
            }
            if containsUnsupported(execution.merged) {
                sawUnsupported = true
                lastReason = .unsupported
                continue
            }

            if execution.status == 0 {
                sawSuccess = true
                if let values = parsePowerMetricsPlistData(execution.stdoutData) {
                    return buildParsedMetrics(sampledAt: sampledAt, values: values, missingReason: .notProvidedByOS)
                }
                lastReason = .parsingFailed
            } else {
                lastReason = reasonFromErrorText(execution.merged, defaultReason: .parsingFailed)
            }
        }

        for args in textArguments {
            guard let execution = runPowerMetrics(arguments: args) else { continue }
            if !execution.merged.isEmpty { lastOutput = execution.merged }

            if containsPermissionDenied(execution.merged) {
                return buildParsedMetrics(sampledAt: sampledAt, values: ParsedValueSet(), missingReason: .permissionDenied)
            }
            if containsUnsupported(execution.merged) {
                sawUnsupported = true
                lastReason = .unsupported
                continue
            }

            if execution.status == 0 {
                sawSuccess = true
                let values = parsePowerMetricsText(execution.stdout)
                return buildParsedMetrics(sampledAt: sampledAt, values: values, missingReason: .notProvidedByOS)
            }

            lastReason = reasonFromErrorText(execution.merged, defaultReason: .parsingFailed)
        }

        if !lastOutput.isEmpty {
            let values = parsePowerMetricsText(lastOutput)
            return buildParsedMetrics(sampledAt: sampledAt, values: values, missingReason: lastReason)
        }

        if sawUnsupported {
            return buildParsedMetrics(sampledAt: sampledAt, values: ParsedValueSet(), missingReason: .unsupported)
        }

        if sawSuccess {
            return buildParsedMetrics(sampledAt: sampledAt, values: ParsedValueSet(), missingReason: .notProvidedByOS)
        }

        return buildParsedMetrics(sampledAt: sampledAt, values: ParsedValueSet(), missingReason: lastReason)
    }

    private func runPowerMetrics(arguments: [String]) -> PowermetricsExecution? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        return PowermetricsExecution(
            stdoutData: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            stderrData: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            status: process.terminationStatus
        )
    }

    private func parsePowerMetricsPlistData(_ data: Data) -> ParsedValueSet? {
        let frames = data.split(separator: 0)
        if frames.isEmpty {
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return nil
            }
            return parsePowerMetricsText(text)
        }

        for frame in frames.reversed() {
            let frameData = Data(frame)
            if let plist = try? PropertyListSerialization.propertyList(from: frameData, options: [], format: nil) {
                let flattened = flattenPlist(plist)
                if !flattened.isEmpty {
                    return parsePowerMetricsText(flattened)
                }
            }
            if let text = String(data: frameData, encoding: .utf8), !text.isEmpty {
                return parsePowerMetricsText(text)
            }
        }

        return nil
    }

    private func flattenPlist(_ object: Any) -> String {
        var lines: [String] = []
        collectScalarLines(from: object, path: nil, output: &lines)
        return lines.joined(separator: "\n")
    }

    private func collectScalarLines(from object: Any, path: String?, output: inout [String]) {
        if let dict = object as? [String: Any] {
            for key in dict.keys.sorted() {
                let nextPath = path.map { "\($0).\(key)" } ?? key
                if let value = dict[key] {
                    collectScalarLines(from: value, path: nextPath, output: &output)
                }
            }
            return
        }
        if let dict = object as? NSDictionary {
            let keys = dict.allKeys.compactMap { $0 as? String }.sorted()
            for key in keys {
                let nextPath = path.map { "\($0).\(key)" } ?? key
                if let value = dict[key] {
                    collectScalarLines(from: value, path: nextPath, output: &output)
                }
            }
            return
        }
        if let array = object as? [Any] {
            for (index, value) in array.enumerated() {
                let nextPath = path.map { "\($0)[\(index)]" } ?? "[\(index)]"
                collectScalarLines(from: value, path: nextPath, output: &output)
            }
            return
        }
        if let number = object as? NSNumber {
            output.append("\(path ?? "value"): \(number.doubleValue)")
            return
        }
        if let text = object as? String {
            output.append("\(path ?? "value"): \(text)")
        }
    }

    private func parsePowerMetricsText(_ text: String) -> ParsedValueSet {
        var parsed = ParsedValueSet()

        parsed.cpuTemperatureC = firstMatchDouble(
            in: text,
            patterns: [
                #"(?im)\bCPU(?:\s+die)?\s+temperature[^0-9-]*([0-9]+(?:\.[0-9]+)?)"#,
                #"(?im)\bCPU\b[^\n]*(?:temperature|temp)[^0-9-]*([0-9]+(?:\.[0-9]+)?)"#,
                #"(?im)\bECPU\b[^\n]*(?:temperature|temp)[^0-9-]*([0-9]+(?:\.[0-9]+)?)"#,
                #"(?im)\bPCPU\b[^\n]*(?:temperature|temp)[^0-9-]*([0-9]+(?:\.[0-9]+)?)"#
            ]
        )
        if parsed.cpuTemperatureC == nil {
            parsed.cpuTemperatureC = fallbackTemperature(in: text, componentHints: ["cpu", "ecpu", "pcpu", "package"])
        }

        parsed.gpuTemperatureC = firstMatchDouble(
            in: text,
            patterns: [
                #"(?im)\bGPU(?:\s+die)?\s+temperature[^0-9-]*([0-9]+(?:\.[0-9]+)?)"#,
                #"(?im)\bGPU\b[^\n]*(?:temperature|temp)[^0-9-]*([0-9]+(?:\.[0-9]+)?)"#,
                #"(?im)\bgfx\b[^\n]*(?:temperature|temp)[^0-9-]*([0-9]+(?:\.[0-9]+)?)"#
            ]
        )
        if parsed.gpuTemperatureC == nil {
            parsed.gpuTemperatureC = fallbackTemperature(in: text, componentHints: ["gpu", "gfx"])
        }

        if let residency = firstMatchDouble(
            in: text,
            patterns: [
                #"(?im)\bGPU\b[^\n]*active[^\n]*residency[^0-9-]*([0-9]+(?:\.[0-9]+)?)\s*%"#,
                #"(?im)\bGPU\b[^\n]*utili[sz]ation[^0-9-]*([0-9]+(?:\.[0-9]+)?)\s*%"#,
                #"(?im)\bGPU\b[^\n]*HW[^\n]*residency[^0-9-]*([0-9]+(?:\.[0-9]+)?)\s*%"#,
                #"(?im)\bGPU\s*Activity\(%\)[^0-9-]*([0-9]+(?:\.[0-9]+)?)"#
            ]
        ) {
            parsed.gpuUsagePercent = min(max(residency, 0), 100)
        }

        parsed.gpuPowerWatts = parseGPUPowerWatts(in: text)

        let fans = parseFanRPMs(in: text)
        parsed.fanRPMs = fans.isEmpty ? nil : fans

        return parsed
    }

    private func fallbackTemperature(in text: String, componentHints: [String]) -> Double? {
        for line in text.split(separator: "\n") {
            let lowered = line.lowercased()
            guard componentHints.contains(where: { lowered.contains($0) }) else { continue }
            guard lowered.contains("temp") || lowered.contains("temperature") else { continue }
            if let value = firstMatchDouble(
                in: String(line),
                patterns: [
                    #"([0-9]+(?:\.[0-9]+)?)\s*(?:°?\s*[cC])"#,
                    #"([0-9]+(?:\.[0-9]+)?)"#
                ]
            ) {
                return value
            }
        }
        return nil
    }

    private func parseGPUPowerWatts(in text: String) -> Double? {
        let patterns = [
            #"(?im)\bGPU\b[^\n]*\bpower\b[^0-9-]*([0-9]+(?:\.[0-9]+)?)\s*(mW|W)\b"#,
            #"(?im)\bGPU\s+Average\s+power[^0-9-]*([0-9]+(?:\.[0-9]+)?)\s*(mW|W)\b"#,
            #"(?im)\bgpu[^\n]*milliwatts?[^0-9-]*([0-9]+(?:\.[0-9]+)?)\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else { continue }

            if match.numberOfRanges > 2,
               let valueRange = Range(match.range(at: 1), in: text),
               let unitRange = Range(match.range(at: 2), in: text),
               let value = Double(text[valueRange]) {
                let unit = text[unitRange].lowercased()
                return unit == "mw" ? value / 1000.0 : value
            }

            if match.numberOfRanges > 1,
               let valueRange = Range(match.range(at: 1), in: text),
               let value = Double(text[valueRange]) {
                return value / 1000.0
            }
        }

        return nil
    }

    private func parseFanRPMs(in text: String) -> [Int] {
        var values = Set<Int>()

        if let regex = try? NSRegularExpression(
            pattern: #"(?im)\bfan(?:\s+\d+)?[^\n]*?([0-9]{3,5})\s*rpm\b"#,
            options: []
        ) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, options: [], range: range) where match.numberOfRanges > 1 {
                guard let valueRange = Range(match.range(at: 1), in: text),
                      let rpm = Int(text[valueRange]) else { continue }
                values.insert(rpm)
            }
        }

        if values.isEmpty {
            for line in text.split(separator: "\n") {
                let lowered = line.lowercased()
                guard lowered.contains("fan") else { continue }
                guard lowered.contains("rpm") || lowered.contains("speed") else { continue }
                if let value = firstMatchDouble(in: String(line), patterns: [#"([0-9]{3,5})"#]) {
                    values.insert(Int(value))
                }
            }
        }

        return Array(values).sorted()
    }

    private func firstMatchDouble(in text: String, patterns: [String]) -> Double? {
        for pattern in patterns {
            if let raw = firstMatch(in: text, pattern: pattern), let value = Double(raw) {
                return value
            }
        }
        return nil
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.numberOfRanges > 1, let group = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[group])
    }

    private func containsPermissionDenied(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("must be invoked as the superuser")
            || text.localizedCaseInsensitiveContains("operation not permitted")
            || text.localizedCaseInsensitiveContains("permission denied")
    }

    private func containsUnsupported(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("unrecognized sampler")
            || text.localizedCaseInsensitiveContains("unsupported")
    }

    private func reasonFromErrorText(_ text: String, defaultReason: MetricUnavailableReason) -> MetricUnavailableReason {
        if containsPermissionDenied(text) { return .permissionDenied }
        if containsUnsupported(text) { return .unsupported }
        return defaultReason
    }

    private func readLoadAverages() -> (Double?, Double?, Double?) {
        var averages = [Double](repeating: 0, count: 3)
        let result = getloadavg(&averages, 3)
        if result == 3 {
            return (averages[0], averages[1], averages[2])
        }
        return (nil, nil, nil)
    }

    private func readMemoryUsagePercent() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        var physicalMemory: UInt64 = 0
        var memSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &physicalMemory, &memSize, nil, 0) == 0, physicalMemory > 0 else {
            return nil
        }

        var pageSizeValue: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSizeValue) == KERN_SUCCESS else {
            return nil
        }

        let pageSize = Double(pageSizeValue)
        let usedPages = Double(stats.active_count + stats.wire_count + stats.compressor_page_count)
        let used = usedPages * pageSize
        return min(max((used / Double(physicalMemory)) * 100.0, 0.0), 100.0)
    }

    private func checkForUpdatedBinaryIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastBinaryCheckAt) >= binaryCheckIntervalSeconds else { return }
        lastBinaryCheckAt = now

        guard let helperBinaryPath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: helperBinaryPath),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return
        }

        if modifiedAt > helperStartedAt.addingTimeInterval(1.0) {
            NSLog("[PowerMetricsHelper] New helper binary detected (mtime=\(modifiedAt), started=\(helperStartedAt)); exiting for launchd relaunch")
            fflush(stdout)
            fflush(stderr)
            exit(EXIT_SUCCESS)
        }
    }

    private func logSnapshotReasonIfNeeded(_ snapshot: Snapshot) {
        let signature = [
            "gpuUsage=\(snapshot.gpuUsageState?.availability.rawValue ?? "nil"):\(snapshot.gpuUsageState?.reason?.rawValue ?? "-")",
            "gpuPower=\(snapshot.gpuPowerState?.availability.rawValue ?? "nil"):\(snapshot.gpuPowerState?.reason?.rawValue ?? "-")",
            "cpuTemp=\(snapshot.cpuTemperatureState?.availability.rawValue ?? "nil"):\(snapshot.cpuTemperatureState?.reason?.rawValue ?? "-")",
            "gpuTemp=\(snapshot.gpuTemperatureState?.availability.rawValue ?? "nil"):\(snapshot.gpuTemperatureState?.reason?.rawValue ?? "-")",
            "fan=\(snapshot.fanState?.availability.rawValue ?? "nil"):\(snapshot.fanState?.reason?.rawValue ?? "-")"
        ].joined(separator: ",")

        guard signature != lastDiagnosticSignature else { return }
        lastDiagnosticSignature = signature
        NSLog("[PowerMetricsHelper] Metric state changed: \(signature)")
    }
}
