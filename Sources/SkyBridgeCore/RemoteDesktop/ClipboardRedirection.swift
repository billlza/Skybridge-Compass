#if os(macOS)
import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog

public enum ClipboardRedirectionError: Error, LocalizedError, Equatable {
    case inactiveSession
    case ownerMismatch
    case payloadTooLarge
    case invalidPayload
    case unsupportedMIMEType
    case pasteboardWriteFailed

    public var errorDescription: String? {
        switch self {
        case .inactiveSession: "剪贴板同步尚未启用。"
        case .ownerMismatch: "该会话未持有剪贴板同步权限。"
        case .payloadTooLarge: "剪贴板内容超过 8 MB 限制。"
        case .invalidPayload: "剪贴板内容格式无效。"
        case .unsupportedMIMEType: "不支持该剪贴板内容类型。"
        case .pasteboardWriteFailed: "无法写入系统剪贴板。"
        }
    }
}

/// The system pasteboard has one explicit remote session owner. Geometry,
/// viewing connections and unrelated session teardown cannot transfer ownership.
@MainActor
public final class ClipboardRedirectionManager: ObservableObject {
    public static let shared = ClipboardRedirectionManager()
    public typealias ChangeHandler = @MainActor (Data, String) -> Void

    @Published public private(set) var isEnabled = false
    private static let maximumPayloadBytes = 8 * 1_024 * 1_024
    private let log = Logger(subsystem: "com.skybridge.compass", category: "ClipboardRedirection")
    private let pasteboard: NSPasteboard
    private var activeSessionId: UUID?
    private var timer: Timer?
    private var onLocalClipboardChanged: ChangeHandler?
    private var lastClipboardHash: SHA256.Digest?
    private var localClipboardChangeCount = 0

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func enable(for sessionId: UUID, onLocalClipboardChanged: @escaping ChangeHandler) {
        self.onLocalClipboardChanged = onLocalClipboardChanged
        guard !isEnabled || activeSessionId != sessionId else { return }
        timer?.invalidate()
        activeSessionId = sessionId
        isEnabled = true
        lastClipboardHash = nil
        localClipboardChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollLocalClipboard(for: sessionId)
            }
        }
    }

    @discardableResult
    public func disable(for sessionId: UUID) -> Bool {
        guard activeSessionId == sessionId else { return false }
        timer?.invalidate()
        timer = nil
        isEnabled = false
        activeSessionId = nil
        onLocalClipboardChanged = nil
        lastClipboardHash = nil
        return true
    }

    /// Checks ownership and writes synchronously on MainActor. An old accepted
    /// payload cannot run later after another controller receives ownership.
    public func setRemoteClipboard(data: Data, mimeType: String, for sessionId: UUID) throws {
        guard isEnabled else { throw ClipboardRedirectionError.inactiveSession }
        guard activeSessionId == sessionId else { throw ClipboardRedirectionError.ownerMismatch }
        guard data.count <= Self.maximumPayloadBytes else { throw ClipboardRedirectionError.payloadTooLarge }

        enum Value { case text(String), image(NSImage) }
        let value: Value
        switch mimeType {
        case "text/plain", "text/plain;charset=utf-8", "text/uri-list":
            guard let text = String(data: data, encoding: .utf8) else {
                throw ClipboardRedirectionError.invalidPayload
            }
            value = .text(text)
        case "image/png", "image/jpeg", "image/tiff":
            guard let image = NSImage(data: data), image.isValid else {
                throw ClipboardRedirectionError.invalidPayload
            }
            value = .image(image)
        default:
            throw ClipboardRedirectionError.unsupportedMIMEType
        }

        let digest = Self.digest(data: data, mimeType: mimeType)
        guard digest != lastClipboardHash else { return }
        pasteboard.clearContents()
        let didWrite: Bool
        switch value {
        case .text(let text): didWrite = pasteboard.setString(text, forType: .string)
        case .image(let image): didWrite = pasteboard.writeObjects([image])
        }
        guard didWrite else { throw ClipboardRedirectionError.pasteboardWriteFailed }
        lastClipboardHash = digest
        localClipboardChangeCount = pasteboard.changeCount
    }

    func pollLocalClipboard(for sessionId: UUID) {
        guard isEnabled, activeSessionId == sessionId,
              localClipboardChangeCount != pasteboard.changeCount else { return }
        localClipboardChangeCount = pasteboard.changeCount

        let payload: (data: Data, mimeType: String)
        if let text = pasteboard.string(forType: .string) {
            payload = (Data(text.utf8), "text/plain")
        } else if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
                  let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) {
            payload = (pngData, "image/png")
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                  let firstURL = urls.first {
            // File content still travels through the separate file-transfer path.
            payload = (Data(firstURL.path.utf8), "text/uri-list")
        } else {
            return
        }
        guard payload.data.count <= Self.maximumPayloadBytes else {
            log.error("Local clipboard payload exceeds the remote transfer limit")
            return
        }
        let digest = Self.digest(data: payload.data, mimeType: payload.mimeType)
        guard digest != lastClipboardHash else { return }
        lastClipboardHash = digest
        // No deferred callback lookup: this payload belongs to this owner now.
        onLocalClipboardChanged?(payload.data, payload.mimeType)
    }

    private static func digest(data: Data, mimeType: String) -> SHA256.Digest {
        var hasher = SHA256()
        hasher.update(data: Data(mimeType.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: data)
        return hasher.finalize()
    }
}
#endif
