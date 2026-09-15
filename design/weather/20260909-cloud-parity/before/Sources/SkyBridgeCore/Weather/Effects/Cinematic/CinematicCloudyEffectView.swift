// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
//
// CinematicCloudyEffectView.swift
// SkyBridgeCore
//
// ☁️ 电影级多云效果（针对“像雾 / 粗糙 / 不够流畅”的反馈做了优化）
// 设计要点（参考 AAA 常见思路，但用 SwiftUI Canvas 可承载的实现方式落地）：
// - 形体：使用 “metaballs + blur + alphaThreshold” 合并多个云团 → 云轮廓清晰，不会像雾一整片糊
// - 光照：同一套云团做 3 次轻量着色（底部阴影 / 主体 / 银边高光） → 立体感更强
// - 性能：云团是简单椭圆填充 + GPU filter；不做每帧 Perlin FBM 计算，减少掉帧
// - 交互：继续复用统一的 InteractiveClearManager.globalOpacity（不改变雪的高级实现）
//
// Created: 2026-01-21
//

import SwiftUI
import CoreGraphics

@available(macOS 14.0, *)
public struct CinematicCloudyEffectView: View {
    private let config: PerformanceConfiguration
    private let coverage: Double

    @ObservedObject private var clearManager: InteractiveClearManager
    @State private var layers: [CloudLayerModel] = []
    @State private var noiseTexture: Image?
    @State private var fineNoiseTexture: Image?
    @State private var isRemoteDesktopActive: Bool = false

    public init(config: PerformanceConfiguration, coverage: Double = 0.75, clearManager: InteractiveClearManager) {
        self.config = config
        self.coverage = max(0.0, min(1.0, coverage))
        self.clearManager = clearManager
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / Double(targetFPS))) { timeline in
            Canvas { context, size in
                renderFrame(context: &context, size: size, now: timeline.date)
            }
        }
        .opacity(clearManager.globalOpacity)
        .ignoresSafeArea()
        .onAppear {
            initializeModel()
        }
        .onReceive(RemoteDesktopManager.shared.metrics) { snapshot in
            isRemoteDesktopActive = snapshot.activeSessions > 0
        }
    }

    // MARK: - Model

    private struct CloudBlob {
        var x01: CGFloat
        var y01: CGFloat
        var r01: CGFloat
        var xScale: CGFloat
        var yScale: CGFloat
        var phase: Double
        var alpha: Double
    }

    private struct CloudLayerModel {
        enum Kind {
            case main      // 主体多云（层状积云/厚云）
            case cirrus    // 二级细节：卷云絮状（高空薄云）
        }

        var kind: Kind
        var blobs: [CloudBlob]
        var speedPxPerSec: CGFloat
        var blur: CGFloat
        var threshold: Double
        var yJitter: CGFloat
        var baseOpacity: Double
    }

    @MainActor
    private func initializeModel() {
        // 两层足够产生“厚云 + 透气层次”，同时把 drawLayer 次数控制在可流畅范围
        layers.removeAll()

        let seed: UInt64 = 0xC10DD0E20260121 ^ UInt64(Int(coverage * 10_000))
        var rng = SplitMix64(seed: seed)

        // 生成一次噪声纹理（用于云体内部细节），避免每帧随机导致“闪烁/粗糙感”
        ensureNoiseTexturesIfNeeded(seed: seed)

        let quality = cloudQuality
        let farCount = quality == .high ? 22 : 16
        let nearCount = quality == .high ? 34 : 24
        let cirrusCount = quality == .high ? 26 : 18

        // 0) 二级细节：卷云（高空薄云，先画，最远层）
        layers.append(
            CloudLayerModel(
                kind: .cirrus,
                blobs: makeCirrusBlobs(count: cirrusCount, rng: &rng),
                speedPxPerSec: 34,
                blur: 7,
                // 卷云更薄，但仍需要可见；阈值过高会让形状变得“断裂/消失”
                threshold: 0.56 - 0.04 * coverage,
                yJitter: 6,
                baseOpacity: 0.26 + 0.10 * coverage
            )
        )

        layers.append(
            CloudLayerModel(
                kind: .main,
                blobs: makeBlobs(count: farCount, rng: &rng, yRange: 0.08...0.28, rRange: 0.055...0.095, alphaRange: 0.55...0.95),
                speedPxPerSec: 14,
                blur: 14,
                // 主云层：降低阈值，避免“几乎看不到云”
                threshold: 0.40 - 0.02 * coverage,
                yJitter: 10,
                baseOpacity: 0.46 + 0.14 * coverage
            )
        )

        layers.append(
            CloudLayerModel(
                kind: .main,
                blobs: makeBlobs(count: nearCount, rng: &rng, yRange: 0.16...0.42, rRange: 0.045...0.085, alphaRange: 0.50...1.00),
                speedPxPerSec: 24,
                blur: 10,
                threshold: 0.44 - 0.02 * coverage,
                yJitter: 14,
                baseOpacity: 0.58 + 0.18 * coverage
            )
        )
    }

    private enum CloudQuality {
        case balanced
        case high
    }

    private var cloudQuality: CloudQuality {
        // 多云不需要 120fps，但需要稳定；在高帧率机器上提高细节（更多 blob）
        if config.targetFrameRate >= 60 && config.maxParticles >= 8000 {
            return .high
        }
        return .balanced
    }

    // MARK: - Render

    private func renderFrame(context: inout GraphicsContext, size: CGSize, now: Date) {
        guard !isRemoteDesktopActive else { return }

        let t = now.timeIntervalSinceReferenceDate
        // ✅ 多云不再铺“灰色天空底”，仅叠加云层本体，让底层主题背景完整透出。

        // 解析噪声纹理（只解析一次，避免在循环内重复 resolve）
        let resolvedNoise = noiseTexture.map { context.resolve($0) }
        let resolvedFineNoise = fineNoiseTexture.map { context.resolve($0) }

        // ☁️ 逐层渲染（每层：先画“云体着色”，再用 blur+alphaThreshold mask 约束形状）
        // 说明：layers[0] 是远层、layers[last] 是近层；这里用 distance(0=近, 1=远) 做衰减更直观
        let denom = Double(max(1, layers.count - 1))
        for (idx, layer) in layers.enumerated() {
            let distance = Double(layers.count - 1 - idx) / denom
            renderLayer(
                context: &context,
                size: size,
                time: t,
                layer: layer,
                distance: distance,
                noise: resolvedNoise,
                fineNoise: resolvedFineNoise
            )
        }
    }

    private func renderLayer(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        layer: CloudLayerModel,
        distance: Double,
        noise: GraphicsContext.ResolvedImage?,
        fineNoise: GraphicsContext.ResolvedImage?
    ) {
        let isCirrus = (layer.kind == .cirrus)

        // 云层主要分布在上半屏，限制绘制/滤镜区域，提升流畅度
        let marginX: CGFloat = isCirrus ? 220 : 260
        let marginY: CGFloat = isCirrus ? 140 : 200
        let heightFrac: CGFloat = isCirrus ? 0.55 : 0.85
        let cloudRect = CGRect(
            x: -marginX,
            y: -marginY,
            width: size.width + marginX * 2,
            height: size.height * heightFrac + marginY * 2
        )

        // 距离：远层更淡，近层更厚、更有对比
        let depthFade = (0.85 - 0.30 * distance)
        // 🔧 可见度增强：多云默认应“看得到云”，因此整体给一个温和 boost
        let visibilityBoost = 1.25 + 0.35 * coverage
        let alpha = max(0.0, min(1.0, layer.baseOpacity * depthFade * visibilityBoost))

        // 光照方向：左上亮、右下暗（AAA 云底层次感的关键）
        let lightPos = CGPoint(x: size.width * 0.28, y: size.height * 0.12)

        context.drawLayer { layerContext in
            // 限制到云区域，减少 blur/threshold 的工作量
            layerContext.clip(to: Path(cloudRect))

            // 1) 云体着色（先画出来，后续用 destinationIn 的 mask 裁剪）
            // 🔧 可见性增强：提高云体本身的“有效不透明度”，避免在深色壁纸上看不到云
            // 备注：cirrus（薄云）更亮、更轻，减少底部阴影与厚重感。
            let topTint = (isCirrus ? Color(red: 0.92, green: 0.94, blue: 0.98) : Color(red: 0.86, green: 0.88, blue: 0.92))
                .opacity((isCirrus ? 0.48 : 0.75) * alpha)
            let midTint = (isCirrus ? Color(red: 0.86, green: 0.88, blue: 0.94) : Color(red: 0.78, green: 0.80, blue: 0.84))
                .opacity((isCirrus ? 0.40 : 0.62) * alpha)
            let bottomTint = (isCirrus ? Color(red: 0.70, green: 0.74, blue: 0.80) : Color(red: 0.55, green: 0.58, blue: 0.64))
                .opacity((isCirrus ? 0.32 : 0.70) * alpha)

            let baseGradient = Gradient(colors: [topTint, midTint, bottomTint])
            layerContext.fill(
                Path(cloudRect),
                with: .linearGradient(
                    baseGradient,
                    startPoint: CGPoint(x: cloudRect.minX, y: cloudRect.minY),
                    endPoint: CGPoint(x: cloudRect.minX, y: cloudRect.maxY)
                )
            )

            // 2) 底部阴影（乘法暗化，让“云底”出来，不像雾）
            if !isCirrus {
                let oldBlend = layerContext.blendMode
                let oldOpacity = layerContext.opacity
                layerContext.blendMode = .multiply
                layerContext.opacity = 0.85
                let shadowGrad = Gradient(colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.10 + 0.18 * coverage)
                ])
                layerContext.fill(
                    Path(cloudRect),
                    with: .linearGradient(
                        shadowGrad,
                        startPoint: CGPoint(x: 0, y: size.height * 0.28),
                        endPoint: CGPoint(x: 0, y: cloudRect.maxY)
                    )
                )
                layerContext.opacity = oldOpacity
                layerContext.blendMode = oldBlend
            }

            // 3) 银边高光（柔和提亮，不用“纯白椭圆”）
            let oldBlend2 = layerContext.blendMode
            let oldOpacity2 = layerContext.opacity
            layerContext.blendMode = .plusLighter
            layerContext.opacity = isCirrus ? 0.55 : 0.75
            let highlight = Gradient(colors: [
                Color.white.opacity((isCirrus ? 0.18 : 0.30) * alpha),
                Color.clear
            ])
            layerContext.fill(
                Path(ellipseIn: CGRect(x: lightPos.x - (isCirrus ? 420 : 520), y: lightPos.y - (isCirrus ? 300 : 380), width: (isCirrus ? 840 : 1040), height: (isCirrus ? 600 : 760))),
                with: .radialGradient(
                    highlight,
                    center: lightPos,
                    startRadius: 0,
                    endRadius: isCirrus ? 420 : 520
                )
            )
            layerContext.opacity = oldOpacity2
            layerContext.blendMode = oldBlend2

            // 4) 云体纹理（两层噪声：低频 + 高频），只作为细节调制
            if let noise, !isCirrus {
                let oldBlend3 = layerContext.blendMode
                let oldOpacity3 = layerContext.opacity
                layerContext.blendMode = .softLight
            layerContext.opacity = (0.08 + 0.06 * coverage) * (0.9 - 0.3 * distance)

                let dx = CGFloat(time * 10).truncatingRemainder(dividingBy: 320) - 160
                let dy = CGFloat(time * 6).truncatingRemainder(dividingBy: 220) - 110
                let noiseRect = cloudRect.insetBy(dx: -320, dy: -220).offsetBy(dx: dx, dy: dy)
                layerContext.draw(noise, in: noiseRect)

                layerContext.opacity = oldOpacity3
                layerContext.blendMode = oldBlend3
            }

            if let fineNoise {
                let oldBlend4 = layerContext.blendMode
                let oldOpacity4 = layerContext.opacity
                layerContext.blendMode = isCirrus ? .softLight : .overlay
                // cirrus 更依赖细节纹理（絮状），因此强一些；主云层细节轻一些避免“脏”
                let fineFactor = isCirrus ? 1.9 : 1.0
                layerContext.opacity = ((0.04 + 0.04 * coverage) * fineFactor) * (0.9 - 0.3 * distance)

                let dx = CGFloat(time * 22).truncatingRemainder(dividingBy: 220) - 110
                let dy = CGFloat(time * 14).truncatingRemainder(dividingBy: 160) - 80
                // cirrus：把纹理横向拉伸，形成更明显的“卷云丝带”
                let fineRect = (isCirrus ? cloudRect.insetBy(dx: -520, dy: -140) : cloudRect.insetBy(dx: -220, dy: -160))
                    .offsetBy(dx: dx, dy: dy)
                layerContext.draw(fineNoise, in: fineRect)

                layerContext.opacity = oldOpacity4
                layerContext.blendMode = oldBlend4
            }

            // 5) 用 blur + alphaThreshold 生成云形 mask，再用 destinationIn 裁剪上面绘制的“云体着色”
            let oldBlendMask = layerContext.blendMode
            layerContext.blendMode = .destinationIn
            layerContext.addFilter(.blur(radius: layer.blur))
            layerContext.addFilter(.alphaThreshold(min: layer.threshold, color: .white))
            drawMaskBlobs(context: &layerContext, size: size, time: time, layer: layer, marginX: marginX, offset: .zero)

            layerContext.blendMode = oldBlendMask
        }

        // 6) 更自然的光照散射（silver lining）：仅对“近层主云”做一次边缘散射，避免性能抖动
        if layer.kind == .main && distance <= 0.05 {
            renderSilverLining(context: &context, size: size, time: time, layer: layer, cloudRect: cloudRect, marginX: marginX)
        }
    }

    private func drawSky(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        // 背景别做“雾化”，给云足够对比与空间
        let top = 0.22 + 0.08 * coverage
        let mid = 0.16 + 0.06 * coverage

        let gradient = Gradient(colors: [
            Color(red: 0.22, green: 0.28, blue: 0.36).opacity(top),
            Color(red: 0.34, green: 0.40, blue: 0.50).opacity(mid),
            Color(red: 0.55, green: 0.60, blue: 0.68).opacity(0.05),
            Color.clear
        ])

        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
        )
    }

    // MARK: - FPS / RNG

    /// 绘制云形 mask 的基础几何（不含滤镜/混合），供 base mask / silver lining 共用。
    private func drawMaskBlobs(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        layer: CloudLayerModel,
        marginX: CGFloat,
        offset: CGSize
    ) {
        let span = size.width + marginX * 2
        let drift = CGFloat(time) * layer.speedPxPerSec

        for blob in layer.blobs {
            // 横向循环滚动，保证无缝
            var x = blob.x01 * size.width + drift
            x = x.truncatingRemainder(dividingBy: span)
            if x < 0 { x += span }
            x = x - marginX + offset.width

            // 轻微竖向扰动（避免静止的“贴图云”）
            let y = blob.y01 * size.height + CGFloat(sin(time * 0.16 + blob.phase) * Double(layer.yJitter)) + offset.height

            let r = blob.r01 * min(size.width, size.height)
            let w = r * 2 * blob.xScale
            let h = r * 2 * blob.yScale
            let rect = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)

            context.fill(
                Path(ellipseIn: rect),
                with: .color(.white)
            )
        }
    }

    /// AAA-ish：更自然的银边散射（silver lining）
    ///
    /// 实现思路：绘制一层“光照渐变”，用“偏移后的云 mask”裁剪，再用“原云 mask”挖空，形成方向性的边缘散射带。
    private func renderSilverLining(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        layer: CloudLayerModel,
        cloudRect: CGRect,
        marginX: CGFloat
    ) {
        // 光源方向（左上）偏移：偏移越大，银边越明显，但也更容易显“描边”
        let rimShift = CGSize(width: -18, height: -14)

        // 强度：覆盖度越大银边越明显
        let rimOpacity = 0.08 + 0.10 * coverage

        let savedBlend = context.blendMode
        context.blendMode = .plusLighter

        context.drawLayer { rimCtx in
            rimCtx.clip(to: Path(cloudRect))

            // 1) 光照散射渐变（略偏暖，贴近真实云边缘透光）
            let lightPos = CGPoint(x: size.width * 0.22, y: size.height * 0.10)
            let r = max(size.width, size.height) * 0.75
            let grad = Gradient(colors: [
                Color(red: 1.00, green: 0.97, blue: 0.90).opacity(rimOpacity),
                Color.clear
            ])
            rimCtx.fill(
                Path(ellipseIn: CGRect(x: lightPos.x - r, y: lightPos.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(grad, center: lightPos, startRadius: 0, endRadius: r)
            )

            // 2) 用“偏移后的云 mask”裁剪（destinationIn）
            rimCtx.blendMode = .destinationIn
            rimCtx.drawLayer { maskCtx in
                maskCtx.addFilter(.blur(radius: layer.blur + 18))
                maskCtx.addFilter(.alphaThreshold(min: min(0.88, layer.threshold + 0.10), color: .white))
                drawMaskBlobs(context: &maskCtx, size: size, time: time, layer: layer, marginX: marginX, offset: rimShift)
            }

            // 3) 用“原云 mask”挖空（destinationOut）→ 只剩光照方向一侧的“边缘带”
            rimCtx.blendMode = .destinationOut
            rimCtx.drawLayer { maskCtx in
                maskCtx.addFilter(.blur(radius: layer.blur + 10))
                maskCtx.addFilter(.alphaThreshold(min: min(0.92, layer.threshold + 0.18), color: .white))
                drawMaskBlobs(context: &maskCtx, size: size, time: time, layer: layer, marginX: marginX, offset: .zero)
            }
        }

        context.blendMode = savedBlend
    }

    private var targetFPS: Int {
        return min(max(30, config.targetFrameRate), 60)
    }

    @MainActor
    private func ensureNoiseTexturesIfNeeded(seed: UInt64) {
        // 只生成一次；纹理本身是静态的，动画通过绘制时的 offset 来实现
        if noiseTexture == nil {
            noiseTexture = Self.makeNoiseTexture(size: 512, seed: seed ^ 0xA11CE_C10DD_0001)
        }
        if fineNoiseTexture == nil {
            fineNoiseTexture = Self.makeNoiseTexture(size: 256, seed: seed ^ 0xA11CE_C10DD_0002)
        }
    }

    private func makeCirrusBlobs(count: Int, rng: inout SplitMix64) -> [CloudBlob] {
        guard count > 0 else { return [] }

        // 卷云：更长、更薄、更高
        let yRange: ClosedRange<Double> = 0.02...0.18
        let rRange: ClosedRange<Double> = 0.020...0.050
        let xScaleRange: ClosedRange<Double> = 2.0...4.6
        let yScaleRange: ClosedRange<Double> = 0.10...0.26

        let bandCount = max(3, Int(round(Double(count) / 6.0)))
        let basePerBand = max(2, count / bandCount)
        var remaining = count

        var out: [CloudBlob] = []
        out.reserveCapacity(count)

        for b in 0..<bandCount {
            let puffs = (b == bandCount - 1) ? remaining : basePerBand
            remaining = max(0, remaining - puffs)

            let centerX = (Double(b) + rng.next01()) / Double(bandCount)
            let centerY = rng.next(in: yRange)
            let bandWidth = rng.next(in: 0.18...0.34)
            let bandHeight = rng.next(in: 0.015...0.040)
            let baseR = rng.next(in: rRange)

            for _ in 0..<puffs {
                var x = centerX + rng.next(in: -bandWidth...bandWidth)
                x = x - floor(x)
                let y = clamp01(centerY + rng.next(in: -bandHeight...bandHeight))

                let r = baseR * rng.next(in: 0.75...1.25)
                let xScale = rng.next(in: xScaleRange)
                let yScale = rng.next(in: yScaleRange)

                out.append(
                    CloudBlob(
                        x01: CGFloat(x),
                        y01: CGFloat(y),
                        r01: CGFloat(r),
                        xScale: CGFloat(xScale),
                        yScale: CGFloat(yScale),
                        phase: rng.next(in: 0.0...Double.pi * 2),
                        alpha: rng.next(in: 0.65...1.0)
                    )
                )
            }
        }

        if out.count > count {
            out.removeLast(out.count - count)
        } else if out.count < count {
            for _ in 0..<(count - out.count) {
                out.append(
                    CloudBlob(
                        x01: CGFloat(rng.next01()),
                        y01: CGFloat(rng.next(in: yRange)),
                        r01: CGFloat(rng.next(in: rRange)),
                        xScale: CGFloat(rng.next(in: xScaleRange)),
                        yScale: CGFloat(rng.next(in: yScaleRange)),
                        phase: rng.next(in: 0.0...Double.pi * 2),
                        alpha: rng.next(in: 0.65...1.0)
                    )
                )
            }
        }

        return out
    }

    private func makeBlobs(
        count: Int,
        rng: inout SplitMix64,
        yRange: ClosedRange<Double>,
        rRange: ClosedRange<Double>,
        alphaRange: ClosedRange<Double>
    ) -> [CloudBlob] {
        guard count > 0 else { return [] }

        // 让云更像“云团/云带”，而不是随机散落的几个椭圆
        let wispCount = max(0, Int(Double(count) * 0.18))
        let mainCount = max(0, count - wispCount)

        let bankCount = max(3, Int(round(Double(max(1, mainCount)) / 6.0)))
        let basePerBank = max(1, mainCount / bankCount)
        var remaining = mainCount

        var out: [CloudBlob] = []
        out.reserveCapacity(count)

        for b in 0..<bankCount {
            let puffs = (b == bankCount - 1) ? remaining : basePerBank
            remaining = max(0, remaining - puffs)

            let centerX = (Double(b) + rng.next01()) / Double(bankCount)
            let centerY = rng.next(in: yRange)
            let bankWidth = rng.next(in: 0.12...0.24)
            let bankHeight = rng.next(in: 0.03...0.07)
            let baseR = rng.next(in: rRange)

            for _ in 0..<puffs {
                var x = centerX + rng.next(in: -bankWidth...bankWidth)
                x = x - floor(x) // wrap to [0,1)

                let y = clamp01(centerY + rng.next(in: -bankHeight...bankHeight))
                let r = baseR * rng.next(in: 0.70...1.35)

                // 形体变化：避免“几个相同椭圆”
                let xScale = rng.next(in: 0.95...1.45)
                let yScale = rng.next(in: 0.42...0.78)

                out.append(
                    CloudBlob(
                        x01: CGFloat(x),
                        y01: CGFloat(y),
                        r01: CGFloat(r),
                        xScale: CGFloat(xScale),
                        yScale: CGFloat(yScale),
                        phase: rng.next(in: 0.0...Double.pi * 2),
                        alpha: rng.next(in: alphaRange)
                    )
                )
            }
        }

        // 少量 wisps：更小、更轻、更高，增强层次但不抢镜
        if wispCount > 0 {
            let wispYMin = clamp01(yRange.lowerBound - 0.08)
            let wispYMax = clamp01(yRange.lowerBound + 0.05)
            for _ in 0..<wispCount {
                let x = rng.next01()
                let y = rng.next(in: min(wispYMin, wispYMax)...max(wispYMin, wispYMax))
                let r = rng.next(in: rRange.lowerBound * 0.55...rRange.upperBound * 0.75)
                let a = rng.next(in: alphaRange.lowerBound * 0.45...alphaRange.upperBound * 0.65)
                out.append(
                    CloudBlob(
                        x01: CGFloat(x),
                        y01: CGFloat(y),
                        r01: CGFloat(r),
                        xScale: CGFloat(rng.next(in: 1.0...1.6)),
                        yScale: CGFloat(rng.next(in: 0.30...0.55)),
                        phase: rng.next(in: 0.0...Double.pi * 2),
                        alpha: a
                    )
                )
            }
        }

        // 保证数量稳定（避免每次 model 变化导致“跳变/闪烁”）
        if out.count > count {
            out.removeLast(out.count - count)
        } else if out.count < count {
            for _ in 0..<(count - out.count) {
                out.append(
                    CloudBlob(
                        x01: CGFloat(rng.next01()),
                        y01: CGFloat(rng.next(in: yRange)),
                        r01: CGFloat(rng.next(in: rRange)),
                        xScale: CGFloat(rng.next(in: 0.95...1.45)),
                        yScale: CGFloat(rng.next(in: 0.42...0.78)),
                        phase: rng.next(in: 0.0...Double.pi * 2),
                        alpha: rng.next(in: alphaRange)
                    )
                )
            }
        }

        return out
    }

    // SplitMix64 PRNG（轻量、确定性、无需依赖其它文件）
    private struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func nextUInt64() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func next01() -> Double {
            // [0,1)
            let v = nextUInt64() >> 11
            return Double(v) / Double(1 << 53)
        }
        mutating func next(in range: ClosedRange<Double>) -> Double {
            return range.lowerBound + (range.upperBound - range.lowerBound) * next01()
        }
    }

    private static func makeNoiseTexture(size: Int, seed: UInt64) -> Image? {
        guard let cg = makeNoiseCGImage(size: size, seed: seed) else { return nil }
        return Image(decorative: cg, scale: 1, orientation: .up)
    }

    private static func makeNoiseCGImage(size: Int, seed: UInt64) -> CGImage? {
        let width = max(64, size)
        let height = max(64, size)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let total = bytesPerRow * height

        var rng = SplitMix64(seed: seed)
        var data = [UInt8](repeating: 0, count: total)

        // “柔一点”的噪声：每像素取 3 次随机的平均，减少生硬颗粒
        for y in 0..<height {
            for x in 0..<width {
                let r1 = rng.next01()
                let r2 = rng.next01()
                let r3 = rng.next01()
                let v = UInt8(max(0, min(255, Int(((r1 + r2 + r3) / 3.0) * 255.0))))
                let i = y * bytesPerRow + x * bytesPerPixel
                data[i + 0] = v
                data[i + 1] = v
                data[i + 2] = v
                data[i + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func clamp01(_ x: Double) -> Double {
        return min(1.0, max(0.0, x))
    }
}

#endif
