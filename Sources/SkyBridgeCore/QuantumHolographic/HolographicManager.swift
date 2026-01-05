import Foundation
import SwiftUI
import OSLog

/// 全息投影管理器 - 基于Apple 2025最佳实践
@MainActor
public class HolographicManager: BaseManager {
    
 // MARK: - 发布的属性
    @Published public var isHolographicActive: Bool = false
    @Published public var quality: HolographicQuality = .high
    @Published public var projectionMode: ProjectionMode = .standard
    @Published public var holographicObjects: [HolographicObject] = []
    
 // MARK: - 初始化
    public init() {
        super.init(category: "HolographicManager")
        logger.info("全息投影管理器已初始化")
    }
    
 // MARK: - 公共方法
    
 /// 启用全息投影
    public func enableHolographicMode() {
        isHolographicActive = true
        logger.info("全息投影模式已启用")
    }
    
 /// 禁用全息投影
    public func disableHolographicMode() {
        isHolographicActive = false
        logger.info("全息投影模式已禁用")
    }
    
 /// 设置投影质量
    public func setQuality(_ quality: HolographicQuality) {
        self.quality = quality
        logger.info("全息投影质量已设置为: \(quality.displayName)")
    }
    
 /// 添加全息对象
    public func addHolographicObject(_ object: HolographicObject) {
        holographicObjects.append(object)
        logger.info("已添加全息对象: \(object.name)")
    }
    
 /// 移除全息对象
    public func removeHolographicObject(_ objectId: String) {
        holographicObjects.removeAll { $0.id == objectId }
        logger.info("已移除全息对象: \(objectId)")
    }
    
 /// 更新全息对象位置
    public func updateObjectPosition(_ objectId: String, position: Vector3D) {
        if let index = holographicObjects.firstIndex(where: { $0.id == objectId }) {
            holographicObjects[index].position = position
            logger.info("已更新全息对象位置: \(objectId)")
        }
    }
}

// MARK: - 全息投影质量

public enum HolographicQuality: String, CaseIterable, Identifiable {
    case low = "低"
    case medium = "中"
    case high = "高"
    case ultra = "超高"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        return rawValue
    }
}

// MARK: - 投影模式

public enum ProjectionMode: String, CaseIterable {
    case standard = "标准"
    case immersive = "沉浸式"
    case mixed = "混合现实"
    
    public var displayName: String {
        return rawValue
    }
}

// MARK: - 全息对象

public struct HolographicObject: Identifiable, Sendable {
    public let id: String
    public let name: String
    public var position: Vector3D
    public var rotation: Vector3D
    public var scale: Vector3D
    public var opacity: Double
    public let createdAt: Date
    
    public init(id: String = UUID().uuidString, name: String, position: Vector3D, rotation: Vector3D = Vector3D(x: 0, y: 0, z: 0), scale: Vector3D = Vector3D(x: 1, y: 1, z: 1), opacity: Double = 1.0) {
        self.id = id
        self.name = name
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.opacity = opacity
        self.createdAt = Date()
    }
}

// MARK: - 3D向量

public struct Vector3D: Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double
    
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
    
    public static let zero = Vector3D(x: 0, y: 0, z: 0)
}