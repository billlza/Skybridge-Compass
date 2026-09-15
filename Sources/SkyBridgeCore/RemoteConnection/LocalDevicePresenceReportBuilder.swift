import Foundation
import SkyBridgeProtocolCore

/// 组装本机的心跳元数据（macOS）。
///
/// 全部字段来自已有的单一事实来源：设备名走 `LocalDevicePresentation`（与 Bonjour/iCloud 展示同名），
/// 机型走 `HardwareModelIdentifier`，局域网地址走 `LocalNetworkAdvertisementAddressProvider`（与广播同一套过滤）。
/// macOS 是唯一可被远程桌面控制的平台，因此上报 `remote_desktop` 能力。
@available(macOS 14.0, *)
public enum LocalDevicePresenceReportBuilder {
    public static func currentReport() throws -> AccountDevicePresenceReport {
        try makeReport(
            presentation: LocalDevicePresentation.current(),
            hardwareModel: HardwareModelIdentifier.current(),
            lanAddresses: LocalNetworkAdvertisementAddressProvider.routableLANAddresses(),
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    /// 纯组装（测试注入用）：不做任何系统调用。
    static func makeReport(
        presentation: LocalDevicePresentation.Snapshot,
        hardwareModel: String?,
        lanAddresses: [String],
        operatingSystemVersion: OperatingSystemVersion
    ) throws -> AccountDevicePresenceReport {
        let trimmedName = presentation.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName = !trimmedName.isEmpty
            ? trimmedName
            : (hardwareModel ?? presentation.modelName ?? "Mac")
        return try AccountDevicePresenceReport(
            deviceName: resolvedName,
            platform: .macOS,
            deviceModel: hardwareModel ?? presentation.modelName,
            osVersion: formattedVersion(operatingSystemVersion),
            lanAddresses: LANAddressRoutabilityPolicy.routableAddresses(
                from: lanAddresses,
                limit: AccountDevicePresenceReport.maximumLANAddresses
            ),
            capabilities: [.remoteDesktop, .fileTransfer, .clipboard]
        )
    }

    static func formattedVersion(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
