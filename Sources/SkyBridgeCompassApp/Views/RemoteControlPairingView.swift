import AppKit
import Combine
import SkyBridgeCore
import SwiftUI

@MainActor
final class RemoteControlPairingViewModel: ObservableObject {
    @Published private(set) var localMaterial: RemoteControlPairingMaterial?
    @Published private(set) var localText: String?
    @Published var importedText = "" {
        didSet { preview = nil; resultMessage = nil }
    }
    @Published private(set) var preview: RemoteControlPairingMaterial?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var resultMessage: String?

    func loadLocalMaterial() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let material = try await RemoteControlPairingService.exportLocalMaterial()
            let bytes = try material.encoded()
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw RemoteControlPairingError.invalidMaterial("UTF-8")
            }
            try Task.checkCancellation()
            localMaterial = material
            localText = text
        } catch is CancellationError {
            // Dismissing the sheet cancels preparation, without changing trust.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func previewImport() {
        errorMessage = nil
        resultMessage = nil
        do {
            preview = try RemoteControlPairingMaterial.decode(Data(importedText.utf8))
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    func trustPreviewedDevice() async {
        guard !isBusy, let material = preview else { return }
        isBusy = true
        errorMessage = nil
        resultMessage = nil
        defer { isBusy = false }
        do {
            let added = try await RemoteControlPairingService.importMaterial(material)
            resultMessage = added ? "已信任 \(material.name)。现在可以返回设备列表连接。" : "\(material.name) 已在可信设备中。"
            preview = nil
        } catch let error as TrustSyncError {
            switch error {
            case .aliasCleanupFailedAfterAuthoritativeCommit, .fallbackCleanupFailedAfterAuthoritativeCommit:
                resultMessage = "已信任 \(material.name)，但旧记录清理失败。"
                preview = nil
            default:
                break
            }
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct RemoteControlPairingView: View {
    @StateObject private var model = RemoteControlPairingViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("配对设备").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
            }
            Text("在两台设备间交换配对信息，核对设备名称和指纹后建立信任。配对信息只包含公钥。")
                .foregroundStyle(.secondary)
            GroupBox("本机配对信息") {
                VStack(alignment: .leading, spacing: 10) {
                    if let material = model.localMaterial {
                        Text(material.name).font(.headline)
                        Text(material.protocolPublicKeyFingerprint)
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    HStack {
                        Button("复制本机配对信息") { copyLocalMaterial() }
                            .disabled(model.localText == nil || model.isBusy)
                            .accessibilityIdentifier("remote-control-pairing-copy")
                        Button("重新读取") { Task { await model.loadLocalMaterial() } }
                            .disabled(model.isBusy)
                        if model.isBusy { ProgressView().controlSize(.small) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("信任另一台设备") {
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $model.importedText)
                        .font(.caption.monospaced())
                        .frame(height: 125)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .disabled(model.isBusy)
                        .accessibilityLabel("另一台设备的配对信息")
                    HStack {
                        Button("粘贴配对信息") { pasteMaterial() }.disabled(model.isBusy)
                        Button("核对设备") { model.previewImport() }
                            .disabled(model.importedText.isEmpty || model.isBusy)
                    }
                    if let preview = model.preview {
                        Text(preview.name).font(.headline)
                        Text(preview.protocolPublicKeyFingerprint)
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Button("信任 \(preview.name)") { Task { await model.trustPreviewedDevice() } }
                            .buttonStyle(.borderedProminent).disabled(model.isBusy)
                            .accessibilityIdentifier("remote-control-pairing-trust")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if let message = model.resultMessage {
                Label(message, systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(width: 600)
        .task { await model.loadLocalMaterial() }
    }

    private func copyLocalMaterial() {
        guard let text = model.localText else { return }
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(text, forType: .string) {
            model.errorMessage = "无法写入剪贴板，请重试。"
        }
    }

    private func pasteMaterial() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            model.errorMessage = "剪贴板中没有配对信息。"
            return
        }
        model.importedText = text
        model.previewImport()
    }
}
