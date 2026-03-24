import Foundation
@preconcurrency import Metal
@preconcurrency import CoreFoundation
import CoreGraphics

// MARK: - 传输函数

/// 光电传输函数 (OETF/EOTF)
public enum TransferFunction: String, Sendable, CaseIterable {
    /// sRGB / BT.709 gamma (~2.2)
    case sRGB = "sRGB"
    /// Perceptual Quantizer (SMPTE ST 2084) — HDR10
    case pq = "PQ"
    /// Hybrid Log-Gamma (ARIB STD-B67) — HLG
    case hlg = "HLG"
    /// 线性光（无传输函数）
    case linear = "Linear"
}

// MARK: - 色调映射模式

/// 色调映射策略
public enum ToneMappingMode: String, Sendable, CaseIterable {
    /// 无色调映射（SDR 直通）
    case none = "none"
    /// 简单 Reinhard 色调映射
    case reinhard = "reinhard"
    /// ACES 电影级色调映射
    case aces = "aces"
    /// 显示适应性色调映射（根据 EDR headroom 自适应）
    case display = "display"
}

// MARK: - 色彩管线配置

/// 统一色彩管线配置。
///
/// 消除渲染器中散装的 `CGColorSpaceCreateDeviceRGB()` 使用，
/// 为 Stable / Fluid / Reference 三层渲染器提供统一的色彩语义。
///
/// 设计原则：
/// 1. 每个渲染模式有明确的色彩配置，不允许隐式推断
/// 2. SDR 和 HDR 是完全独立的路径，不混在一起
/// 3. 色彩空间、像素格式、传输函数、色调映射 一一对应
public struct ColorPipelineConfiguration: Sendable {

    /// 编码端（源）色彩空间
    public let sourceColorSpaceName: CFString

    /// 渲染端（目标）色彩空间
    public let renderColorSpaceName: CFString

    /// Metal 纹理像素格式
    public let pixelFormat: MTLPixelFormat

    /// 光电传输函数
    public let transferFunction: TransferFunction

    /// 色调映射模式
    public let toneMappingMode: ToneMappingMode

    /// 是否启用 EDR 扩展动态范围
    public let enableEDR: Bool

    /// 最大 EDR headroom（仅 HDR 模式有效）
    public let maxEDRHeadroom: CGFloat

    public init(
        sourceColorSpaceName: CFString,
        renderColorSpaceName: CFString,
        pixelFormat: MTLPixelFormat,
        transferFunction: TransferFunction,
        toneMappingMode: ToneMappingMode,
        enableEDR: Bool = false,
        maxEDRHeadroom: CGFloat = 1.0
    ) {
        self.sourceColorSpaceName = sourceColorSpaceName
        self.renderColorSpaceName = renderColorSpaceName
        self.pixelFormat = pixelFormat
        self.transferFunction = transferFunction
        self.toneMappingMode = toneMappingMode
        self.enableEDR = enableEDR
        self.maxEDRHeadroom = maxEDRHeadroom
    }

    // MARK: - 预设配置

    /// SDR 标准动态范围 (BT.709 / sRGB)
    ///
    /// 用于 Stable 和 Fluid 模式的默认色彩配置。
    /// 8-bit BGRA，sRGB gamma，无色调映射。
    public static let sdr = ColorPipelineConfiguration(
        sourceColorSpaceName: CGColorSpace.sRGB,
        renderColorSpaceName: CGColorSpace.sRGB,
        pixelFormat: .bgra8Unorm,
        transferFunction: .sRGB,
        toneMappingMode: .none,
        enableEDR: false,
        maxEDRHeadroom: 1.0
    )

    /// HDR 高动态范围 (Display P3 + PQ + EDR)
    ///
    /// 用于 Reference 模式。
    /// 16-bit float RGBA，PQ 传输函数，显示自适应色调映射。
    public static let hdr = ColorPipelineConfiguration(
        sourceColorSpaceName: CGColorSpace.displayP3,
        renderColorSpaceName: CGColorSpace.extendedLinearDisplayP3,
        pixelFormat: .rgba16Float,
        transferFunction: .pq,
        toneMappingMode: .display,
        enableEDR: true,
        maxEDRHeadroom: 2.0
    )

    /// HDR HLG (BT.2100 HLG)
    ///
    /// 用于 HLG 内容源的 Reference 模式。
    public static let hlg = ColorPipelineConfiguration(
        sourceColorSpaceName: CGColorSpace.itur_2020,
        renderColorSpaceName: CGColorSpace.extendedLinearDisplayP3,
        pixelFormat: .rgba16Float,
        transferFunction: .hlg,
        toneMappingMode: .display,
        enableEDR: true,
        maxEDRHeadroom: 2.0
    )

    /// 10-bit SDR 宽色域 (Display P3，无 HDR)
    ///
    /// 介于 SDR 和 HDR 之间的高质量模式。
    /// 用于 Display P3 显示器上的高色彩精度场景。
    public static let wideGamutSDR = ColorPipelineConfiguration(
        sourceColorSpaceName: CGColorSpace.displayP3,
        renderColorSpaceName: CGColorSpace.displayP3,
        pixelFormat: .bgr10a2Unorm,
        transferFunction: .sRGB,
        toneMappingMode: .none,
        enableEDR: false,
        maxEDRHeadroom: 1.0
    )

    // MARK: - 工具方法

    /// 创建源色彩空间对象
    public func makeSourceColorSpace() -> CGColorSpace? {
        CGColorSpace(name: sourceColorSpaceName)
    }

    /// 创建渲染色彩空间对象
    public func makeRenderColorSpace() -> CGColorSpace? {
        CGColorSpace(name: renderColorSpaceName)
    }

    /// 是否为 HDR 模式
    public var isHDR: Bool {
        enableEDR && transferFunction != .sRGB
    }

    /// 每像素字节数
    public var bytesPerPixel: Int {
        switch pixelFormat {
        case .bgra8Unorm: return 4
        case .rgba16Float: return 8
        case .bgr10a2Unorm: return 4
        default: return 4
        }
    }
}
