import Foundation
import Metal

/// Immutable ownership lease for one decoded texture publication.
///
/// The lease intentionally retains the decoder backing object until the Metal
/// drawable reports that this exact frame was presented. `RemoteTextureFrame`
/// is MainActor-isolated, so neither the texture nor its backing is accessed
/// from the drawable callback thread; the callback only retains the lease and
/// hands it back to `RemoteTextureFeed` on MainActor.
@MainActor
public final class RemoteTextureFrame {
    public let texture: MTLTexture

    fileprivate let presentationEpoch: UInt64
    fileprivate let presentationSequence: UInt64
    private let backingObject: AnyObject?

    fileprivate init(
        texture: MTLTexture,
        backingObject: AnyObject?,
        presentationEpoch: UInt64,
        presentationSequence: UInt64
    ) {
        self.texture = texture
        self.backingObject = backingObject
        self.presentationEpoch = presentationEpoch
        self.presentationSequence = presentationSequence
    }
}

/// 将解码后的远端帧纹理桥接到 UI 层的发布者。
/// - 设计动机：`RemoteDesktopManager` 与会话层在核心模块，UI 位于 App 模块，
/// 通过一个轻量的 ObservableObject 将 `MTLTexture` 作为只读快照传递，
/// 避免直接依赖 UI；同时遵循 macOS 下 Metal 的零拷贝最佳实践，
/// 仅在 GPU 可见对象引用上做发布而不进行数据复制。
@MainActor
public final class RemoteTextureFeed: ObservableObject {
    /// 最新的远端帧及其 backing ownership lease。UI 侧收到更新后触发一次绘制。
    @Published public private(set) var frame: RemoteTextureFrame?

    /// 保留现有只读 API；需要呈现确认的 UI 必须订阅 `frame`，不能只消费裸纹理。
    public var texture: MTLTexture? { frame?.texture }

    private var presentationEpoch: UInt64 = 0
    private var nextPresentationSequence: UInt64 = 0
    private var lastReportedPresentationSequence: UInt64 = 0
    private var presentationCompletionHandler: (@MainActor () -> Void)?

    public init() {}

 /// 由会话渲染器在主线程更新纹理引用。
 /// - Parameter texture: 解码并转换为 Metal 的纹理对象。
    public func update(texture: MTLTexture?, backing: AnyObject? = nil) {
        guard let texture else {
            invalidatePresentationEpoch()
            frame = nil
            return
        }

        nextPresentationSequence &+= 1
        frame = RemoteTextureFrame(
            texture: texture,
            backingObject: backing,
            presentationEpoch: presentationEpoch,
            presentationSequence: nextPresentationSequence
        )
    }

    /// Installs the session-owned presentation boundary. Replacing or removing
    /// the handler invalidates every outstanding drawable callback from the
    /// previous session epoch.
    func setPresentationCompletionHandler(
        _ handler: (@MainActor () -> Void)?
    ) {
        invalidatePresentationEpoch()
        presentationCompletionHandler = handler
    }

    /// Called only from `MTLDrawable.addPresentedHandler` after AppKit/Metal
    /// confirms that the drawable containing this frame reached presentation.
    /// Stale epochs, duplicate callbacks and out-of-order older completions are
    /// ignored fail-closed.
    public func reportPresentedFrame(_ presentedFrame: RemoteTextureFrame) {
        guard presentedFrame.presentationEpoch == presentationEpoch,
              presentedFrame.presentationSequence > lastReportedPresentationSequence,
              presentedFrame.presentationSequence <= nextPresentationSequence,
              let presentationCompletionHandler else {
            return
        }
        lastReportedPresentationSequence = presentedFrame.presentationSequence
        presentationCompletionHandler()
    }

    private func invalidatePresentationEpoch() {
        presentationEpoch &+= 1
        nextPresentationSequence = 0
        lastReportedPresentationSequence = 0
    }
}
