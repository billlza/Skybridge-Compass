import SwiftUI
import Metal
import MetalKit
import Combine
import os.log
import SkyBridgeCore

/// SwiftUI 包装的 MTKView，用于在屏幕上呈现远端 GPU 纹理。
/// - 设计遵循 Apple 官方在 MTKView 文档中的建议：迟取 drawable、在命令缓冲上注册呈现、
///   使用显式绘制模式减少无效帧。
struct RemoteDisplayView: NSViewRepresentable {
    let textureFeed: RemoteTextureFeed

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true                  // 显式绘制：仅在收到新纹理时绘制
        view.enableSetNeedsDisplay = false    // 不使用 setNeedsDisplay 驱动
        view.framebufferOnly = true           // 仅作为显示目标，提高驱动优化
        view.delegate = context.coordinator
        context.coordinator.attach(view: view, feed: textureFeed)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // 视图尺寸或环境变化时由 MTKView 自身处理；纹理更新通过 feed 触发 draw()
    }
    
    static func dismantleNSView(_ nsView: MTKView, coordinator: RendererCoordinator) {
        // 在视图销毁时清理资源
        coordinator.detach()
    }

    func makeCoordinator() -> RendererCoordinator {
        RendererCoordinator()
    }

    /// 渲染协调器：构建管线并在收到新纹理时编码一次全屏绘制。
    @MainActor
    final class RendererCoordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice!
        private var commandQueue: MTLCommandQueue!
        private var pipelineState: MTLRenderPipelineState!
        private var vertexBuffer: MTLBuffer!
        private weak var view: MTKView?
        private var cancellable: AnyCancellable?
        private var latestTexture: MTLTexture?

        /// 绑定 MTKView 与纹理发布者。
        func attach(view: MTKView, feed: RemoteTextureFeed) {
            self.view = view
            guard let device = view.device else { return }
            self.device = device
            self.commandQueue = device.makeCommandQueue()

            // 运行时编译着色器库。若迁移到 Xcode App 目标，可改为 makeDefaultLibrary() 加载 .metal 文件。
            let shaderSource = Self.basicShaderSource
            let library = try? device.makeLibrary(source: shaderSource, options: nil)
            let vertexFunc = library?.makeFunction(name: "passthroughVertex")
            let fragmentFunc = library?.makeFunction(name: "blitFragment")

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)

            // 全屏矩形（两三角），NDC 坐标与纹理坐标。
            struct Vertex { var pos: SIMD2<Float>; var uv: SIMD2<Float> }
            let quad: [Vertex] = [
                Vertex(pos: [-1, -1], uv: [0, 1]),
                Vertex(pos: [ 1, -1], uv: [1, 1]),
                Vertex(pos: [-1,  1], uv: [0, 0]),
                Vertex(pos: [-1,  1], uv: [0, 0]),
                Vertex(pos: [ 1, -1], uv: [1, 1]),
                Vertex(pos: [ 1,  1], uv: [1, 0])
            ]
            vertexBuffer = device.makeBuffer(bytes: quad, length: MemoryLayout<Vertex>.stride * quad.count, options: .storageModeShared)

            // 订阅纹理更新：收到新纹理时触发一次显式绘制。
            cancellable = feed.$texture
                .receive(on: DispatchQueue.main)
                .sink { [weak self] (tex: MTLTexture?) in
                    guard let self = self else { return }
                    self.latestTexture = tex
                    self.view?.draw()
                }
        }
        
        func detach() {
            // 手动清理订阅
            cancellable?.cancel()
            cancellable = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // 视图尺寸变化无需特殊处理；渲染为全屏矩形。
        }

        func draw(in view: MTKView) {
            guard let commandQueue, let pipelineState else { return }
            guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }

            let commandBuffer = commandQueue.makeCommandBuffer()
            let encoder = commandBuffer?.makeRenderCommandEncoder(descriptor: descriptor)
            encoder?.setRenderPipelineState(pipelineState)
            encoder?.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            if let texture = latestTexture {
                encoder?.setFragmentTexture(texture, index: 0)
            }
            encoder?.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder?.endEncoding()

            // 注册呈现并提交命令缓冲，遵循 MTKView 文档的推荐流程。
            commandBuffer?.present(drawable)
            commandBuffer?.commit()
        }

        /// 基本着色器：直通顶点 + 采样片段，将远端纹理贴到屏幕。
        private static let basicShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
        struct VSOut { float4 position [[position]]; float2 uv; };

        vertex VSOut passthroughVertex(uint vid [[vertex_id]], const device VertexIn* vertices [[buffer(0)]]) {
            VSOut out;
            out.position = float4(vertices[vid].pos, 0.0, 1.0);
            out.uv = vertices[vid].uv;
            return out;
        }

        fragment float4 blitFragment(VSOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            return tex.sample(s, in.uv);
        }
        """
    }
}