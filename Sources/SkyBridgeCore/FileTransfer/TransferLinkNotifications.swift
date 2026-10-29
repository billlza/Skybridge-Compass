// 传输链接相关通知名。
//
// 抽取自 FileTransfer/QRCodeGenerator.swift（该文件依赖 NSImage/NSViewRepresentable，为 macOS 专属），
// 因为共享的 TransferLinkManager 在链接过期时发布该通知。通知名是跨平台契约，不应与某个平台的
// 展示实现耦合在同一文件。

import Foundation

extension Notification.Name {
    /// 传输链接已过期。发布方为 `TransferLinkManager`，订阅方包含 macOS 的二维码展示层。
    static let transferLinkExpired = Notification.Name("transferLinkExpired")
}
