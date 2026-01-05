import Foundation
import Metal

/// 将解码后的远端帧纹理桥接到 UI 层的发布者。
/// - 设计动机：`RemoteDesktopManager` 与会话层在核心模块，UI 位于 App 模块，
/// 通过一个轻量的 ObservableObject 将 `MTLTexture` 作为只读快照传递，
/// 避免直接依赖 UI；同时遵循 macOS 下 Metal 的零拷贝最佳实践，
/// 仅在 GPU 可见对象引用上做发布而不进行数据复制。
@MainActor
public final class RemoteTextureFeed: ObservableObject {
 /// 最新的远端帧纹理。UI 侧收到更新后触发一次绘制。
    @Published public private(set) var texture: MTLTexture?

    public init() {}

 /// 由会话渲染器在主线程更新纹理引用。
 /// - Parameter texture: 解码并转换为 Metal 的纹理对象。
    public func update(texture: MTLTexture?) {
        self.texture = texture
    }
}