import AppKit
import SkyBridgeCore
import SkyBridgeProtocolCore
import SwiftUI

@available(macOS 14.0, *)
struct LanDirectConnectionShareView: View {
    var embedded = false
    private struct Presentation {
        let info: LanDirectConnectionInfo
        let text: String
        let image: CGImage
    }
    @Environment(\.dismiss) private var dismiss
    @State private var options: [LanDirectConnectionInfo] = []
    @State private var selectedHost = ""
    @State private var loading = true
    @State private var copying = false
    @State private var status: String?
    @State private var failed = false
    @State private var presentation: Presentation?
    @State private var showsConnectionText = false
    @State private var qrRevision = UUID()
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("连接到这台 Mac", systemImage: "qrcode").font(.title2)
            Text("使用手机 SkyBridge 的“扫码连接”。随后在两端核对设备身份。")
                .fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
            if loading { ProgressView("正在读取本机连接信息…") }
            Text("手机与 Mac 需要能通过局域网互相访问。切换网络后请刷新二维码。")
                .font(.caption).foregroundStyle(.secondary)
            if let current = presentation, current.info.host == selectedHost, options.contains(current.info), !loading {
                HStack {
                    Spacer()
                    Image(decorative: current.image, scale: 2)
                        .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                        .frame(width: 264, height: 264).padding(8).background(.white)
                        .accessibilityLabel("连接本机二维码")
                    Spacer()
                }
            } else if !loading, !options.isEmpty, !failed {
                ProgressView("正在生成二维码…")
            }
            if !options.isEmpty {
                DisclosureGroup("高级连接信息", isExpanded: $showsConnectionText) {
                    Picker("网络地址", selection: $selectedHost) {
                        ForEach(options, id: \.host) { option in
                            Text(verbatim: "\(option.host):\(option.port)").tag(option.host)
                        }
                    }.disabled(loading || copying)
                    Text("连接不成功时，可选择手机能访问的另一个局域网地址。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let current = presentation, current.info.host == selectedHost, !loading {
                        Text(current.text).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).accessibilityLabel("本机直连信息")
                    }
                }
            }
            if let status {
                Text(status).foregroundStyle(failed ? Color.red : Color.secondary).textSelection(.enabled)
            }
            HStack {
                Button("刷新") { startReload() }.disabled(loading || copying)
                Button("复制连接信息") { copyCurrent() }
                    .disabled(loading || copying || presentation?.info.host != selectedHost || presentation == nil)
                Spacer()
                if !embedded { Button("完成") { dismiss() }.buttonStyle(.borderedProminent) }
            }
        }
        .padding(embedded ? 0 : 24).frame(width: embedded ? nil : 520)
        .task { await reload() }
        .task(id: qrRevision) { await renderSelectedQRCode() }
        .onChange(of: selectedHost) { _, _ in qrRevision = UUID() }
        .onDisappear { operation?.cancel() }
    }

    @MainActor private func startReload() {
        operation?.cancel()
        operation = Task { await reload() }
    }

    @MainActor private func reload() async {
        loading = true; status = nil; failed = false; presentation = nil
        do {
            let current = try await LocalLanDirectConnectionService.connectionOptions()
            try Task.checkCancellation()
            options = current
            if !current.contains(where: { $0.host == selectedHost }) {
                selectedHost = current.first?.host ?? ""
            }
        } catch is CancellationError {
            return
        } catch {
            options = []; selectedHost = ""; failed = true
            status = error.localizedDescription
        }
        loading = false
        qrRevision = UUID()
    }

    @MainActor private func renderSelectedQRCode() async {
        guard !loading, let selected = options.first(where: { $0.host == selectedHost }) else { return }
        presentation = nil; status = nil; failed = false
        do {
            let text = try await LocalLanDirectConnectionService.textForCurrentOption(selected)
            try Task.checkCancellation()
            let image = try LanDirectConnectionQRCode.image(for: selected)
            try Task.checkCancellation()
            guard selectedHost == selected.host, options.contains(selected) else { return }
            presentation = .init(info: selected, text: text, image: image)
        } catch is CancellationError {
            return
        } catch {
            failed = true
            SkyBridgeLogger.discovery.error("LAN QR render failed: \(String(reflecting: type(of: error)), privacy: .public)")
            status = "无法生成当前连接二维码，请刷新后重试。"
        }
    }

    @MainActor private func copyCurrent() {
        guard let selected = presentation?.info, selected.host == selectedHost, options.contains(selected) else { return }
        operation?.cancel()
        copying = true; status = nil; failed = false
        operation = Task {
            do {
                let text = try await LocalLanDirectConnectionService.textForCurrentOption(selected)
                try Task.checkCancellation()
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else {
                    failed = true; status = "无法写入剪贴板，请重试。"; copying = false
                    return
                }
                status = "已复制连接信息，可在手机的高级连接入口粘贴。"
            } catch is CancellationError {
                return
            } catch {
                presentation = nil
                failed = true; status = error.localizedDescription
            }
            copying = false
        }
    }
}
