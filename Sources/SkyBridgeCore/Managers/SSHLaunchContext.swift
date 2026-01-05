import Foundation

/// SSH 启动上下文（窗口间共享）
/// 中文说明：用于从“新建连接”表单向 SSH 终端窗口传递主机、端口、用户名等参数。
@MainActor
public final class SSHLaunchContext: ObservableObject {
    public static let shared = SSHLaunchContext()
    @Published public var host: String?
    @Published public var port: Int?
    @Published public var username: String?
    @Published public var password: String?
    private init() {}
}