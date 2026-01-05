import Foundation

/// VNC 启动上下文（窗口间共享）
/// 中文说明：用于从“新建连接”表单向 VNC 查看器窗口传递主机与端口参数。
@MainActor
public final class VNCLaunchContext: ObservableObject {
    public static let shared = VNCLaunchContext()
    @Published public var host: String?
    @Published public var port: UInt16?
    private init() {}
}