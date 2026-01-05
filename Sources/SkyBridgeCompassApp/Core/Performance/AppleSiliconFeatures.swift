//
// AppleSiliconFeatures.swift
// SkyBridgeCompassApp
//
// Apple Silicon 特性检测器
// 使用 Swift 6.2 新特性进行设备能力检测
//

import Foundation
import Metal
import OSLog

/// Apple Silicon 特性检测器
public struct AppleSiliconFeatures: Sendable {
 /// 是否支持统一内存架构
    public let hasUnifiedMemory: Bool
 /// 是否支持 Neural Engine
    public let hasNeuralEngine: Bool
 /// 是否支持 AMX 协处理器
    public let hasAMX: Bool
 /// 芯片型号
    public let chipModel: String
 /// 性能核心数
    public let performanceCores: Int
 /// 效率核心数
    public let efficiencyCores: Int
    
 /// 初始化特性检测器
    public init() {
        var size = 0
        var cpuBrand = "Unknown"
        
 // 获取 CPU 品牌信息
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brandString = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brandString, &size, nil, 0)
        
        let nullTerminatedData = Data(bytes: brandString, count: size)
        if let nullIndex = nullTerminatedData.firstIndex(of: 0) {
            let truncatedData = nullTerminatedData.prefix(upTo: nullIndex)
            cpuBrand = String(decoding: truncatedData, as: UTF8.self)
        } else {
            cpuBrand = String(decoding: nullTerminatedData, as: UTF8.self)
        }
        
        self.chipModel = cpuBrand
        
 // 检测 Apple Silicon 特性
        let isAppleSilicon = cpuBrand.contains("Apple")
        self.hasUnifiedMemory = isAppleSilicon
        
 // 根据芯片型号检测特性
        if cpuBrand.contains("M1") {
            self.hasNeuralEngine = true
            self.hasAMX = true
        } else if cpuBrand.contains("M2") || cpuBrand.contains("M3") || cpuBrand.contains("M4") {
            self.hasNeuralEngine = true
            self.hasAMX = true
        } else {
            self.hasNeuralEngine = false
            self.hasAMX = false
        }
        
 // 获取核心数量
        var totalCores: Int32 = 0
        var performanceCores: Int32 = 0
        var efficiencyCores: Int32 = 0
        
        size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &totalCores, &size, nil, 0)
        sysctlbyname("hw.perflevel0.logicalcpu", &performanceCores, &size, nil, 0)
        sysctlbyname("hw.perflevel1.logicalcpu", &efficiencyCores, &size, nil, 0)
        
        self.performanceCores = Int(performanceCores)
        self.efficiencyCores = Int(efficiencyCores)
    }
}

extension AppleSiliconFeatures: CustomStringConvertible {
    public var description: String {
        return "芯片: \(chipModel), 统一内存: \(hasUnifiedMemory), Neural Engine: \(hasNeuralEngine), AMX: \(hasAMX), 性能核心: \(performanceCores), 效率核心: \(efficiencyCores)"
    }
}