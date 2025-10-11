import Foundation
import Metal
import MetalKit
import MetalFX

/// MetalFX处理器 - 实现画质增强和性能优化
@MainActor
public class MetalFXProcessor {
    
    // MARK: - 私有属性
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    
    // MetalFX组件
    private var upscaler: MTLFXSpatialScaler?
    private var temporalUpscaler: MTLFXTemporalScaler?
    private var denoiser: Any? // MTLFXDenoiser在某些版本可能不可用
    
    // 纹理资源
    private var inputTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var motionVectorTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    
    // 配置参数
    private var inputWidth: Int = 1920
    private var inputHeight: Int = 1080
    private var outputWidth: Int = 3840
    private var outputHeight: Int = 2160
    
    private var isEnabled: Bool = true
    private var qualityMode: MetalFXQuality = .balanced
    
    // MARK: - 初始化
    
    public init(device: MTLDevice) throws {
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalFXError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        
        try setupMetalFX()
        print("✅ MetalFX处理器初始化完成")
    }
    
    // MARK: - 公共方法
    
    /// 应用MetalFX增强
    public func applyEnhancements(commandBuffer: MTLCommandBuffer) async throws {
        guard isEnabled else { return }
        
        // 应用空间超采样
        if let upscaler = upscaler {
            try await applySpatialUpscaling(commandBuffer: commandBuffer, upscaler: upscaler)
        }
        
        // 应用时域超采样
        if let temporalUpscaler = temporalUpscaler {
            try await applyTemporalUpscaling(commandBuffer: commandBuffer, upscaler: temporalUpscaler)
        }
        
        // 应用降噪
        try await applyDenoising(commandBuffer: commandBuffer)
    }
    
    /// 设置输入分辨率
    public func setInputResolution(width: Int, height: Int) {
        inputWidth = width
        inputHeight = height
        
        // 重新创建纹理
        Task {
            do {
                try await recreateTextures()
            } catch {
                print("⚠️ 纹理重新创建失败: \(error)")
            }
        }
    }
    
    /// 设置输出分辨率
    public func setOutputResolution(width: Int, height: Int) {
        outputWidth = width
        outputHeight = height
        
        // 重新创建纹理
        Task {
            do {
                try await recreateTextures()
            } catch {
                print("⚠️ 纹理重新创建失败: \(error)")
            }
        }
    }
    
    /// 设置质量模式
    public func setQualityMode(_ mode: MetalFXQuality) {
        guard qualityMode != mode else { 
            print("🔄 MetalFX质量模式已是 \(mode.rawValue)，跳过重新配置")
            return 
        }
        
        qualityMode = mode
        print("🎯 MetalFX质量模式更改为: \(mode.rawValue)")
        
        Task { @MainActor in
            do {
                try reconfigureMetalFX()
            } catch {
                print("❌ MetalFX重新配置失败: \(error.localizedDescription)")
            }
        }
    }
    
    /// 启用/禁用MetalFX
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        print("MetalFX \(enabled ? "已启用" : "已禁用")")
    }
    
    /// 获取推荐的输入分辨率
    public func getRecommendedInputResolution(for outputResolution: CGSize) -> CGSize {
        let scaleFactor: CGFloat
        
        switch qualityMode {
        case .performance:
            scaleFactor = 0.5 // 50%渲染分辨率
        case .balanced:
            scaleFactor = 0.67 // 67%渲染分辨率
        case .quality:
            scaleFactor = 0.77 // 77%渲染分辨率
        case .ultraQuality:
            scaleFactor = 0.9 // 90%渲染分辨率
        }
        
        return CGSize(
            width: outputResolution.width * scaleFactor,
            height: outputResolution.height * scaleFactor
        )
    }
    
    // MARK: - 私有方法
    
    /// 设置MetalFX
    private func setupMetalFX() throws {
        // 检查设备是否支持MetalFX (简化检查，因为supportsDevice方法可能不可用)
        if !device.supportsFamily(.apple7) && !device.supportsFamily(.apple8) {
            throw MetalFXError.deviceNotSupported
        }
        
        try createSpatialUpscaler()
        try createTemporalUpscaler()
        try createTextures()
        
        print("🎨 MetalFX组件设置完成")
    }
    
    /// 创建空间超采样器
    private func createSpatialUpscaler() throws {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.outputTextureFormat = .rgba16Float
        
        guard let upscaler = descriptor.makeSpatialScaler(device: device) else {
            throw MetalFXError.spatialUpscalerCreationFailed
        }
        
        self.upscaler = upscaler
        print("📈 空间超采样器创建成功")
    }
    
    /// 创建时域超采样器
    private func createTemporalUpscaler() throws {
        // 检查是否支持时域超采样 (简化检查)
        if !device.supportsFamily(.apple7) && !device.supportsFamily(.apple8) {
            print("⚠️ 设备不支持时域超采样")
            return
        }
        
        let descriptor = MTLFXTemporalScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.depthTextureFormat = .depth32Float
        descriptor.motionTextureFormat = .rg16Float
        descriptor.outputTextureFormat = .rgba16Float
        
        guard let temporalUpscaler = descriptor.makeTemporalScaler(device: device) else {
            print("⚠️ 时域超采样器创建失败")
            return
        }
        
        self.temporalUpscaler = temporalUpscaler
        print("⏰ 时域超采样器创建成功")
    }
    
    /// 创建纹理资源
    private func createTextures() throws {
        // 输入纹理
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: inputWidth,
            height: inputHeight,
            mipmapped: false
        )
        inputDescriptor.usage = [.shaderRead, .renderTarget]
        
        guard let inputTex = device.makeTexture(descriptor: inputDescriptor) else {
            throw MetalFXError.textureCreationFailed
        }
        self.inputTexture = inputTex
        
        // 输出纹理
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderWrite, .shaderRead]
        
        guard let outputTex = device.makeTexture(descriptor: outputDescriptor) else {
            throw MetalFXError.textureCreationFailed
        }
        self.outputTexture = outputTex
        
        // 运动矢量纹理
        let motionDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float,
            width: inputWidth,
            height: inputHeight,
            mipmapped: false
        )
        motionDescriptor.usage = [.shaderRead, .renderTarget]
        
        guard let motionTex = device.makeTexture(descriptor: motionDescriptor) else {
            throw MetalFXError.textureCreationFailed
        }
        self.motionVectorTexture = motionTex
        
        // 深度纹理
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: inputWidth,
            height: inputHeight,
            mipmapped: false
        )
        depthDescriptor.usage = [.shaderRead, .renderTarget]
        
        guard let depthTex = device.makeTexture(descriptor: depthDescriptor) else {
            throw MetalFXError.textureCreationFailed
        }
        self.depthTexture = depthTex
        
        print("🖼️ MetalFX纹理资源创建完成")
    }
    
    /// 重新创建纹理
    private func recreateTextures() async throws {
        try createTextures()
        
        // 重新配置MetalFX组件
        try reconfigureMetalFX()
    }
    
    /// 重新配置MetalFX
    private func reconfigureMetalFX() throws {
        try createSpatialUpscaler()
        try createTemporalUpscaler()
        print("🔄 MetalFX组件重新配置完成")
    }
    
    /// 应用空间超采样
    private func applySpatialUpscaling(
        commandBuffer: MTLCommandBuffer,
        upscaler: MTLFXSpatialScaler
    ) async throws {
        guard let inputTexture = inputTexture,
              let outputTexture = outputTexture else {
            throw MetalFXError.textureNotAvailable
        }
        
        // 设置输入输出纹理
        upscaler.colorTexture = inputTexture
        upscaler.outputTexture = outputTexture
        
        // 根据质量模式调整参数
        switch qualityMode {
        case .performance:
            // 性能优先模式的参数调整
            break
        case .balanced:
            // 平衡模式的参数调整
            break
        case .quality:
            // 质量优先模式的参数调整
            break
        case .ultraQuality:
            // 超高质量模式的参数调整
            break
        }
        
        // 编码超采样命令
        upscaler.encode(commandBuffer: commandBuffer)
        
        print("📈 空间超采样已应用")
    }
    
    /// 应用时域超采样
    private func applyTemporalUpscaling(
        commandBuffer: MTLCommandBuffer,
        upscaler: MTLFXTemporalScaler
    ) async throws {
        guard let inputTexture = inputTexture,
              let outputTexture = outputTexture,
              let motionVectorTexture = motionVectorTexture,
              let depthTexture = depthTexture else {
            throw MetalFXError.textureNotAvailable
        }
        
        // 设置输入纹理
        upscaler.colorTexture = inputTexture
        upscaler.depthTexture = depthTexture
        upscaler.motionTexture = motionVectorTexture
        upscaler.outputTexture = outputTexture
        
        // 设置时域参数
        upscaler.exposureTexture = nil // 可选的曝光纹理
        upscaler.preExposure = 1.0
        upscaler.jitterOffsetX = 0.0
        upscaler.jitterOffsetY = 0.0
        upscaler.motionVectorScaleX = 1.0
        upscaler.motionVectorScaleY = 1.0
        upscaler.reset = false
        
        // 编码时域超采样命令
        upscaler.encode(commandBuffer: commandBuffer)
        
        print("⏰ 时域超采样已应用")
    }
    
    /// 应用降噪
    private func applyDenoising(commandBuffer: MTLCommandBuffer) async throws {
        // 由于MTLFXDenoiser可能在某些版本不可用，我们实现一个简化的降噪
        // 在实际应用中，这里应该使用MetalFX的降噪器
        
        guard let inputTexture = inputTexture,
              let outputTexture = outputTexture else {
            return
        }
        
        // 创建简单的降噪计算着色器
        guard let library = device.makeDefaultLibrary(),
              let denoiseFunction = library.makeFunction(name: "simple_denoise_compute") else {
            // 如果没有降噪着色器，跳过降噪步骤
            return
        }
        
        do {
            let computePipelineState = try await device.makeComputePipelineState(function: denoiseFunction)
            
            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                return
            }
            
            computeEncoder.setComputePipelineState(computePipelineState)
            computeEncoder.setTexture(inputTexture, index: 0)
            computeEncoder.setTexture(outputTexture, index: 1)
            
            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroupCount = MTLSize(
                width: (outputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
                height: (outputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
                depth: 1
            )
            
            computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.endEncoding()
            
            print("🔧 降噪处理已应用")
            
        } catch {
            print("⚠️ 降噪处理失败: \(error)")
        }
    }
}

// MARK: - 支持类型定义

/// MetalFX质量模式
public enum MetalFXQuality: String, CaseIterable, Sendable {
    case performance = "性能"
    case balanced = "平衡"
    case quality = "质量"
    case ultraQuality = "超高质量"
}

/// MetalFX错误类型
public enum MetalFXError: Error, LocalizedError {
    case deviceNotSupported
    case commandQueueCreationFailed
    case spatialUpscalerCreationFailed
    case temporalUpscalerCreationFailed
    case textureCreationFailed
    case textureNotAvailable
    case shaderCompilationFailed
    
    public var errorDescription: String? {
        switch self {
        case .deviceNotSupported:
            return "设备不支持MetalFX"
        case .commandQueueCreationFailed:
            return "命令队列创建失败"
        case .spatialUpscalerCreationFailed:
            return "空间超采样器创建失败"
        case .temporalUpscalerCreationFailed:
            return "时域超采样器创建失败"
        case .textureCreationFailed:
            return "纹理创建失败"
        case .textureNotAvailable:
            return "纹理不可用"
        case .shaderCompilationFailed:
            return "着色器编译失败"
        }
    }
}