// MARK: - Widget URL Builder
// Deep Link URL 生成器
// Requirements: 1.4, 2.5

import Foundation

/// Widget URL 构建器
public enum WidgetURLBuilder {
    public static let scheme = "skybridge"
    
 /// 生成设备列表 URL
    public static func devicesURL() -> URL {
        URL(string: "\(scheme)://devices")!
    }
    
 /// 生成指定设备详情 URL
 /// - Parameter deviceId: 设备 ID
 /// - Returns: URL，如果 deviceId 无效则返回 nil
    public static func deviceDetailURL(deviceId: String) -> URL? {
        guard !deviceId.isEmpty,
              let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "\(scheme)://devices/\(encoded)")
    }
    
 /// 生成系统监控 URL
    public static func monitorURL() -> URL {
        URL(string: "\(scheme)://monitor")!
    }
    
 /// 生成文件传输 URL
    public static func transfersURL() -> URL {
        URL(string: "\(scheme)://transfers")!
    }
    
 /// 生成扫描设备 URL
 /// 注意：这会打开 App 并开始扫描，不是后台扫描
    public static func scanURL() -> URL {
        URL(string: "\(scheme)://scan")!
    }
    
 /// 生成首页 URL（兜底）
    public static func homeURL() -> URL {
        URL(string: "\(scheme)://")!
    }
}
