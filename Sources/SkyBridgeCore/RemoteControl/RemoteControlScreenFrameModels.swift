import Foundation

enum RemoteControlWireLimits {
    static let aesGCMCombinedOverheadBytes = 28

    static func maxWireMessageBytes(for plaintextLimit: Int) -> Int {
        plaintextLimit + aesGCMCombinedOverheadBytes
    }
}

/// 屏幕数据（近距镜像主载体）
/// imageData 通常为压缩后的视频帧（H.264 / HEVC），或者退化为静态图像字节
struct ScreenData: Codable, Sendable {
    let width: Int
    let height: Int
    let imageData: Data
    let timestamp: TimeInterval
    /// "hevc" / "h264" / 其他（静态图像）
    let format: String?
    /// 压缩视频帧是否为关键帧；对 JPEG/BGRA 等独立帧固定视为 true。
    let isSyncFrame: Bool?
    /// 编码帧序号；用于接收端识别 H.264/HEVC 预测链缺口。
    let sequenceNumber: UInt64?

    init(
        width: Int,
        height: Int,
        imageData: Data,
        timestamp: TimeInterval,
        format: String? = nil,
        isSyncFrame: Bool? = nil,
        sequenceNumber: UInt64? = nil
    ) {
        self.width = width
        self.height = height
        self.imageData = imageData
        self.timestamp = timestamp
        self.format = format
        self.isSyncFrame = isSyncFrame
        self.sequenceNumber = sequenceNumber
    }
}
