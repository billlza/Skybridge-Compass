//
// AudioRedirection.swift
// SkyBridge Compass Pro
//
// 音频重定向功能 - 支持 RDP 和 UltraStream
// 符合 Swift 6.2.1 和 macOS 26.x 最佳实践
// 使用 Core Audio 和 AVFoundation
//

import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import OSLog
import Combine

/// 音频重定向管理器
/// 支持双向音频流：本地音频 <-> 远程音频
@MainActor
public final class AudioRedirectionManager: ObservableObject, @unchecked Sendable {
    
    public static let shared = AudioRedirectionManager()
    
    private let log = Logger(subsystem: "com.skybridge.compass", category: "AudioRedirection")
    
 /// 是否启用音频重定向
    @Published public var isEnabled: Bool = false
    
 /// 当前会话 ID
    private var activeSessionId: UUID?
    
 /// 音频引擎
    private var audioEngine: AVAudioEngine?
    
 /// 音频输入节点（捕获本地音频）
    private var inputNode: AVAudioInputNode?
    
 /// 音频播放节点（播放远程音频）
    private var playerNode: AVAudioPlayerNode?
    
 /// 音频格式
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    
 /// 音频数据回调（发送到远程）
    public var onAudioDataCaptured: ((Data) -> Void)?
    
 /// 远程音频数据接收回调
    public var onRemoteAudioDataReceived: ((Data) -> Void)?
    
 /// 音频队列（处理音频数据）
    private let audioQueue = DispatchQueue(label: "com.skybridge.audio", attributes: .concurrent)
    
    private init() {
 // 请求音频权限
        requestAudioPermission()
    }
    
 /// 请求音频权限
    private func requestAudioPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            log.info("✅ 音频权限已授予")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted {
                    self?.log.info("✅ 音频权限已授予")
                } else {
                    self?.log.warning("⚠️ 音频权限被拒绝")
                }
            }
        default:
            log.warning("⚠️ 音频权限未授予")
        }
    }
    
 /// 启用音频重定向
 /// - Parameter sessionId: 会话 ID
    public func enable(for sessionId: UUID) throws {
        guard !isEnabled || activeSessionId != sessionId else { return }
        
 // 停止现有引擎
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
        }
        
 // 创建新的音频引擎
        let engine = AVAudioEngine()
        self.audioEngine = engine
        
 // 配置输入节点（捕获本地音频）
        let inputNode = engine.inputNode
        self.inputNode = inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
 // 安装音频输入 tap
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isEnabled else { return }
            self.handleAudioInput(buffer: buffer)
        }
        
 // 配置播放节点（播放远程音频）
        let playerNode = AVAudioPlayerNode()
        self.playerNode = playerNode
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: audioFormat)
        
 // 启动音频引擎
        try engine.start()
        
        isEnabled = true
        activeSessionId = sessionId
        
        log.info("✅ 音频重定向已启用: sessionId=\(sessionId.uuidString)")
    }
    
 /// 禁用音频重定向
    public func disable() {
        guard isEnabled else { return }
        
 // 移除输入 tap
        inputNode?.removeTap(onBus: 0)
        
 // 停止播放节点
        playerNode?.stop()
        
 // 停止音频引擎
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        playerNode = nil
        
        isEnabled = false
        activeSessionId = nil
        
        log.info("🛑 音频重定向已禁用")
    }
    
 /// 处理音频输入（捕获本地音频并发送到远程）
    private func handleAudioInput(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        
 // 转换为 Data（交错格式）
        var audioData = Data(capacity: frameLength * channelCount * MemoryLayout<Float>.size)
        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                let sample = channelData[channel][frame]
                withUnsafeBytes(of: sample) { audioData.append(contentsOf: $0) }
            }
        }
        
 // 发送到远程（在主线程执行回调）
        Task { @MainActor [weak self] in
            self?.onAudioDataCaptured?(audioData)
        }
    }
    
 /// 播放远程音频数据
 /// - Parameter audioData: 音频数据（PCM Float32，48kHz，立体声）
    public func playRemoteAudio(_ audioData: Data) {
        guard isEnabled, let engine = audioEngine, engine.isRunning else { return }
        
 // 将 Data 转换为 AVAudioPCMBuffer
        let frameCount = audioData.count / (MemoryLayout<Float>.size * 2) // 立体声
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        
        buffer.frameLength = AVAudioFrameCount(frameCount)
        
 // 解析音频数据（交错格式）
        audioData.withUnsafeBytes { rawBufferPointer in
            let samples = rawBufferPointer.bindMemory(to: Float.self)
            guard let leftChannel = buffer.floatChannelData?[0],
                  let rightChannel = buffer.floatChannelData?[1] else {
                return
            }
            
            for i in 0..<frameCount {
                leftChannel[i] = samples[i * 2]
                rightChannel[i] = samples[i * 2 + 1]
            }
        }
        
 // 播放音频
        if let playerNode = playerNode {
            playerNode.scheduleBuffer(buffer) {
 // 播放完成回调
            }
        }
    }
    
    deinit {
 // 在 deinit 中直接清理资源
 // 注意：这些操作在 deinit 中是安全的，因为对象正在被销毁
        if let node = inputNode {
            node.removeTap(onBus: 0)
        }
        if let player = playerNode {
            player.stop()
        }
        if let engine = audioEngine {
            engine.stop()
        }
    }
}
