import Foundation
@preconcurrency import Metal
import VideoToolbox
import IOKit.ps
import os.log

// MARK: - 硬件能力探测

/// 探测当前设备是否满足 Reference（高保真）渲染模式的硬件要求。
///
/// 检测项：
/// 1. HEVC Main10 硬件解码能力
/// 2. 10-bit 像素格式支持
/// 3. EDR 扩展动态范围支持
/// 4. Display P3 宽色域覆盖
/// 5. Metal GPU 能力族（Apple 8+ = M1+）
/// 6. 功耗状态（电池 vs 外接电源）
/// 7. 热状态
///
/// 全部通过 → `isReferenceCapable = true`
/// 任一不通过 → 强制降级到 Fluid
public struct HardwareCapabilityProbe: Sendable {

    // MARK: - 探测结果

    /// 单项探测结果
    public struct ProbeResult: Sendable {
        public let capability: String
        public let supported: Bool
        public let detail: String

        public init(capability: String, supported: Bool, detail: String) {
            self.capability = capability
            self.supported = supported
            self.detail = detail
        }
    }

    /// 完整探测报告
    public struct ProbeReport: Sendable {
        public let results: [ProbeResult]
        public let timestamp: Date
        public let isReferenceCapable: Bool

        /// 未通过的项目
        public var failures: [ProbeResult] {
            results.filter { !$0.supported }
        }

        /// 摘要描述
        public var summary: String {
            if isReferenceCapable {
                return "Reference mode: all \(results.count) checks passed"
            } else {
                let failNames = failures.map(\.capability).joined(separator: ", ")
                return "Reference mode blocked: \(failNames)"
            }
        }
    }

    private static let log = Logger(subsystem: "com.skybridge.compass", category: "HardwareProbe")

    // MARK: - 主探测接口

    /// 执行完整硬件能力探测。
    ///
    /// - Parameter requireExternalPower: 是否要求外接电源（默认 false，即电池也允许但会降低上限）
    /// - Returns: 探测报告，包含每项的通过/失败及原因
    @MainActor
    public static func probe(requireExternalPower: Bool = false) -> ProbeReport {
        var results: [ProbeResult] = []

        results.append(probeHEVCMain10HardwareDecode())
        results.append(probe10BitPixelFormat())
        results.append(probeEDRSupport())
        results.append(probeDisplayP3())
        results.append(probeMetalGPUFamily())
        results.append(probeThermalState())

        if requireExternalPower {
            results.append(probePowerSource())
        }

        let allPassed = results.allSatisfy(\.supported)

        let report = ProbeReport(
            results: results,
            timestamp: Date(),
            isReferenceCapable: allPassed
        )

        log.info("\(report.summary)")
        return report
    }

    // MARK: - 单项探测

    /// 1. HEVC Main10 硬件解码
    private static func probeHEVCMain10HardwareDecode() -> ProbeResult {
        let supported = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        return ProbeResult(
            capability: "HEVC Main10 HW Decode",
            supported: supported,
            detail: supported ? "Hardware HEVC decoder available" : "No hardware HEVC decoder"
        )
    }

    /// 2. 10-bit 像素格式支持
    private static func probe10BitPixelFormat() -> ProbeResult {
        // 尝试创建一个 10-bit CVPixelBuffer 来验证支持
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: 64,
            kCVPixelBufferHeightKey: 64,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64, 64,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attrs as CFDictionary,
            &pixelBuffer
        )
        let supported = status == kCVReturnSuccess && pixelBuffer != nil
        return ProbeResult(
            capability: "10-bit Pixel Format",
            supported: supported,
            detail: supported ? "420YpCbCr10BiPlanar available" : "10-bit pixel buffer creation failed: \(status)"
        )
    }

    /// 3. EDR 扩展动态范围支持
    @MainActor
    private static func probeEDRSupport() -> ProbeResult {
        #if canImport(AppKit)
        let maxEDR = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        let supported = maxEDR > 1.0
        return ProbeResult(
            capability: "EDR Support",
            supported: supported,
            detail: "Max EDR component value: \(String(format: "%.2f", maxEDR))"
        )
        #else
        return ProbeResult(
            capability: "EDR Support",
            supported: false,
            detail: "AppKit not available (non-macOS platform)"
        )
        #endif
    }

    /// 4. Display P3 宽色域
    @MainActor
    private static func probeDisplayP3() -> ProbeResult {
        #if canImport(AppKit)
        guard let screen = NSScreen.main,
              let colorSpace = screen.colorSpace else {
            return ProbeResult(
                capability: "Display P3",
                supported: false,
                detail: "No main screen or color space"
            )
        }
        // Display P3 的 ICC 名称通常包含 "P3" 或 "Display P3"
        let name = colorSpace.localizedName ?? ""
        let supported = name.contains("P3") || colorSpace.colorSpaceModel == .rgb
        return ProbeResult(
            capability: "Display P3",
            supported: supported,
            detail: "Screen color space: \(name)"
        )
        #else
        return ProbeResult(
            capability: "Display P3",
            supported: false,
            detail: "AppKit not available"
        )
        #endif
    }

    /// 5. Metal GPU 能力族（要求 Apple 8+ = M1+）
    private static func probeMetalGPUFamily() -> ProbeResult {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return ProbeResult(
                capability: "Metal GPU Family",
                supported: false,
                detail: "No Metal device"
            )
        }
        let supportsApple8 = device.supportsFamily(.apple8)
        return ProbeResult(
            capability: "Metal GPU Family",
            supported: supportsApple8,
            detail: supportsApple8
                ? "Apple 8+ (M1+) supported"
                : "Below Apple 8 family"
        )
    }

    /// 6. 热状态
    private static func probeThermalState() -> ProbeResult {
        let state = ProcessInfo.processInfo.thermalState
        let acceptable = state == .nominal || state == .fair
        let stateNames: [ProcessInfo.ThermalState: String] = [
            .nominal: "nominal",
            .fair: "fair",
            .serious: "serious",
            .critical: "critical"
        ]
        return ProbeResult(
            capability: "Thermal State",
            supported: acceptable,
            detail: "Current: \(stateNames[state] ?? "unknown")"
        )
    }

    /// 7. 外接电源检测
    private static func probePowerSource() -> ProbeResult {
        let onAC = isOnExternalPower()
        return ProbeResult(
            capability: "External Power",
            supported: onAC,
            detail: onAC ? "Connected to external power" : "Running on battery"
        )
    }

    // MARK: - 功耗工具

    /// 检测是否接入外接电源
    public static func isOnExternalPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [Any],
              !sources.isEmpty else {
            // 台式机没有电池 → 视为外接电源
            return true
        }

        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(info, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
               let powerSource = desc[kIOPSPowerSourceStateKey] as? String {
                if powerSource == kIOPSACPowerValue {
                    return true
                }
            }
        }
        return false
    }

    /// 查询当前 EDR headroom
    @MainActor
    public static func currentEDRHeadroom() -> CGFloat {
        #if canImport(AppKit)
        return NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        #else
        return 1.0
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif
