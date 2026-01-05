import Foundation
import CoreLocation

/// 城市密度分类器（离线）
/// 使用经纬度网格与城市边界的近似包围盒进行城市/郊区分类，避免在线查询带来的阻塞与隐私风险。
/// 说明：该实现为可扩展的离线映射，当前内置少量示例数据（北京、上海、广州、深圳、杭州），
/// 后续可以通过配置文件或数据补丁扩展更多城市与更精细的网格。
@MainActor
public final class UrbanDensityClassifier: ObservableObject, Sendable {
    public static let shared = UrbanDensityClassifier()
    
 /// 城市区域包围盒（经纬度）
    public struct UrbanBoundingBox: Sendable {
 /// 城市名称（可选，仅用于日志与调试）
        public let cityName: String?
 /// 最小纬度、最小经度、最大纬度、最大经度
        public let minLat: Double
        public let minLon: Double
        public let maxLat: Double
        public let maxLon: Double
        
        public init(cityName: String?, minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
            self.cityName = cityName
            self.minLat = minLat
            self.minLon = minLon
            self.maxLat = maxLat
            self.maxLon = maxLon
        }
        
 /// 判断点是否在包围盒内
        public func contains(lat: Double, lon: Double) -> Bool {
            return lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
        }
    }
    
 /// 内置示例城市包围盒（近似范围）
    private let builtinUrbanBoxes: [UrbanBoundingBox] = [
 // 北京（近似范围）
        UrbanBoundingBox(cityName: "北京", minLat: 39.4, minLon: 115.7, maxLat: 41.0, maxLon: 117.6),
 // 上海（近似范围）
        UrbanBoundingBox(cityName: "上海", minLat: 30.9, minLon: 120.8, maxLat: 31.6, maxLon: 122.0),
 // 广州（近似范围）
        UrbanBoundingBox(cityName: "广州", minLat: 22.5, minLon: 112.9, maxLat: 23.7, maxLon: 114.1),
 // 深圳（近似范围）
        UrbanBoundingBox(cityName: "深圳", minLat: 22.4, minLon: 113.8, maxLat: 22.9, maxLon: 114.6),
 // 杭州（近似范围）
        UrbanBoundingBox(cityName: "杭州", minLat: 29.0, minLon: 118.0, maxLat: 30.8, maxLon: 121.0)
    ]
    
 /// 用户自定义的城市包围盒（可通过配置扩展）
    @Published public private(set) var customUrbanBoxes: [UrbanBoundingBox] = []
    
    private init() {}
    
 /// 添加自定义城市包围盒
    public func addCustomUrbanBox(_ box: UrbanBoundingBox) {
        customUrbanBoxes.append(box)
    }
    
 /// 清空自定义包围盒
    public func clearCustomUrbanBoxes() {
        customUrbanBoxes.removeAll()
    }
    
 /// 判断是否为城市区域（优先使用经纬度判断，其次回退到城市名称关键字）
 /// - Parameters:
 /// - latitude: 纬度
 /// - longitude: 经度
 /// - city: 城市名称（可选）
 /// - Returns: 是否属于城市区域
    public func isUrban(latitude: Double?, longitude: Double?, city: String?) -> Bool {
 // 1) 经纬度判断（优先、更可靠）
        if let lat = latitude, let lon = longitude {
            for box in customUrbanBoxes + builtinUrbanBoxes {
                if box.contains(lat: lat, lon: lon) { return true }
            }
        }
        
 // 2) 名称关键字回退（当经纬度不可用时）
        if let c = city?.lowercased(), !c.isEmpty {
            let urbanKeywords = ["市", "城区", "中心", "city", "downtown", "urban"]
            let suburbanKeywords = ["县", "乡", "镇", "村", "county", "town", "village", "suburb"]
            if suburbanKeywords.contains(where: { c.contains($0) }) { return false }
            if urbanKeywords.contains(where: { c.contains($0) }) { return true }
 // 有明确城市名则默认视为城市
            return true
        }
        
 // 3) 缺省：未知视为郊区（更保守）
        return false
    }
}