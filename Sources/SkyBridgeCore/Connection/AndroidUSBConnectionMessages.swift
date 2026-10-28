#if os(macOS)
import Foundation
import IOKit
import CSkyBridgeUSBHost
import SkyBridgeAppleTransport
import SkyBridgeProtocolCore

extension AndroidUSBConnectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPeer: return String(localized: "所选设备缺少有效的配对身份，请先完成配对。")
        case .alreadyConnecting: return String(localized: "请先结束当前 USB 连接。")
        case .unavailable: return String(localized: "USB 安全连接未能建立，请确认两端 SkyBridge 均已打开。")
        case .attachmentChanged: return String(localized: "手机的 USB 连接已变化，请刷新设备后重试。")
        case .ambiguousAttachment: return String(localized: "无法确定原线缆上的手机，请重新插拔后刷新设备。")
        case .reenumerationTimedOut: return String(localized: "等待手机切换 USB 模式超时，请确认手机上的连接提示。")
        case .unownedAccessory: return String(localized: "这条 USB 连接需要重新准备。请重新插拔线缆，再刷新设备并连接。")
        case .interfaceBusy: return String(localized: "手机的 USB 接口正被其他程序或驱动占用，暂时无法连接。")
        case .cleanupUnconfirmed: return String(localized: "尚未确认 USB 资源已释放，请先完成断开。")
        case .connectionLost: return String(localized: "USB 连接已中断，请检查手机提示后重新连接。")
        }
    }
}

public enum AndroidUSBFailureRecovery: Sendable, Equatable {
    case reviewDriverExtensions
}

public struct AndroidUSBFailurePresentation: Sendable, Equatable {
    public let message: String
    public let recovery: AndroidUSBFailureRecovery?
    init(_ message: String, recovery: AndroidUSBFailureRecovery? = nil) {
        self.message = message; self.recovery = recovery
    }
}

extension AndroidUSBConnectionCoordinator {
    public var failurePresentation: AndroidUSBFailurePresentation? { failure.map { Self.presentFailure($0) } }
    public var failureMessage: String? { failurePresentation?.message }

    static func describeFailure(_ error: any Error, depth: Int = 0) -> String {
        presentFailure(error, depth: depth).message
    }

    /// Message and recovery are derived together from the original structured
    /// cause. Matching user-visible text must never select a recovery action.
    static func presentFailure(_ error: any Error, depth: Int = 0) -> AndroidUSBFailurePresentation {
        guard depth < 8 else { return .init(String(localized: "USB 操作发生多重错误，请查看诊断记录。")) }
        if let native = error as? USBHostFailure {
            if native.status == SB_USB_NATIVE_FAILURE.rawValue,
               native.phase == SB_USB_PHASE_OPEN.rawValue,
               native.domain == SB_USB_DOMAIN_IORETURN.rawValue,
               native.nativeCode == kIOReturnExclusiveAccess {
                return .init(AndroidUSBConnectionError.interfaceBusy.localizedDescription, recovery: .reviewDriverExtensions)
            }
            return .init(String(localized: "USB 系统操作失败，错误码：") + String(native.nativeCode))
        }
        if case .interfaceBusy? = error as? AndroidUSBConnectionError {
            return .init(error.localizedDescription, recovery: .reviewDriverExtensions)
        }
        if case .profileMismatch? = error as? USBHostAccessoryError {
            return .init(String(localized: "两端 SkyBridge 的 USB 连接版本不兼容，请更新后重新连接。"))
        }
        if let failure = error as? USBHostAccessoryPreparationFailure {
            if let cause = failure.cause { return presentFailure(cause, depth: depth + 1) }
            if let native = failure.receipt.operationFailure { return presentFailure(native, depth: depth + 1) }
            return .init(String(localized: "手机未能完成 USB 连接准备。"))
        }
        if let failure = error as? AndroidUSBPreparationCleanupFailure {
            let primary = presentFailure(failure.primary, depth: depth + 1)
            let cleanup = presentFailure(failure.cleanup, depth: depth + 1)
            return .init(primary.message + String(localized: "；断开时也发生错误：") + cleanup.message,
                         recovery: primary.recovery ?? cleanup.recovery)
        }
        if let failure = error as? AndroidUSBSessionCleanupFailure {
            let causes = failure.failures.map { presentFailure($0, depth: depth + 1) }
            guard !causes.isEmpty else { return .init(String(localized: "USB 断开失败，缺少详细错误信息。")) }
            return .init(causes.map(\.message).joined(separator: "；"), recovery: causes.compactMap(\.recovery).first)
        }
        if (error as? USBHostByteError) == .timedOut ||
            (error as? USBHostMultiplexError) == .timedOut ||
            (error as? USBLinkEpochProtocol.Failure) == .timeout {
            return .init(String(localized: "connection.usb.retryTimeout", bundle: .module))
        }
        if error is USBLogicalStreamError { return .init(AndroidUSBConnectionError.connectionLost.localizedDescription) }
        return .init(error.localizedDescription)
    }
}

extension USBDeviceInventoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "系统暂时无法读取 USB 设备。")
        case .native(let operation, let code): return String(localized: "读取 USB 设备失败：") + "\(operation) (\(code))"
        case .malformedProperties: return String(localized: "系统返回的 USB 设备信息不完整。")
        case .enumerationChanged: return String(localized: "读取期间 USB 设备发生变化，请刷新。")
        case .tooManyDevices: return String(localized: "USB 设备数量超出本次扫描上限。")
        case .cleanup: return String(localized: "读取 USB 设备后，系统资源释放未获确认。")
        }
    }
}
#endif
