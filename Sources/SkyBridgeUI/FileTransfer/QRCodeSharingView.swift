import OSLog
import SkyBridgeCore
import SwiftUI
import CoreImage.CIFilterBuiltins

/// QR码分享视图 - 使用统一的 TransferLinkManager 分享文件
struct QRCodeSharingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var qrCodeImage: NSImage?
    @State private var serverURL: String = ""
    @State private var isServerRunning = false
    @State private var connectionCode: String = ""
    @State private var currentLink: TransferLink?

    let selectedFiles: [URL]

    var body: some View {
        VStack(spacing: 0) {
            macOSTitleBar

            ScrollView {
                VStack(spacing: 24) {
                    qrCodeCard
                    connectionInfoCard
                    if !selectedFiles.isEmpty {
                        fileListCard
                    }
                }
                .padding(20)
            }

            macOSBottomBar
        }
        .frame(minWidth: 480, minHeight: 600)
        .background(.ultraThinMaterial)
        .task {
            await generateConnectionInfo()
        }
        .onDisappear {
            stopServer()
        }
    }

    private var macOSTitleBar: some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizationManager.shared.localizedString("qrcode.title"))
                        .font(.headline)
                        .fontWeight(.semibold)

                    Text(LocalizationManager.shared.localizedString("qrcode.subtitle"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(LocalizationManager.shared.localizedString("action.closeWindow"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.thickMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var qrCodeCard: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThickMaterial)
                    .frame(width: 280, height: 280)
                    .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)

                if let qrImage = qrCodeImage {
                    VStack(spacing: 16) {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 220, height: 220)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)

                        HStack(spacing: 8) {
                            Circle()
                                .fill(isServerRunning ? .green : .orange)
                                .frame(width: 8, height: 8)

                            Text(isServerRunning ? LocalizationManager.shared.localizedString("qrcode.status.running") : LocalizationManager.shared.localizedString("qrcode.status.ready"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)

                        Text(LocalizationManager.shared.localizedString("qrcode.generating"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }

            VStack(spacing: 8) {
                Text(LocalizationManager.shared.localizedString("qrcode.instruction.title"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(LocalizationManager.shared.localizedString("qrcode.instruction.subtitle"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private var connectionInfoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "network")
                    .foregroundColor(.blue)
                    .font(.title3)

                Text(LocalizationManager.shared.localizedString("qrcode.connectionInfo"))
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            VStack(spacing: 12) {
                if !serverURL.isEmpty {
                    macOSInfoRow(
                        title: LocalizationManager.shared.localizedString("qrcode.serverAddress"),
                        value: serverURL,
                        icon: "globe",
                        isMonospaced: true
                    )
                }

                if !connectionCode.isEmpty {
                    macOSInfoRow(
                        title: LocalizationManager.shared.localizedString("qrcode.connectionCode"),
                        value: connectionCode,
                        icon: "number.square",
                        isMonospaced: true,
                        isHighlighted: true
                    )
                }

                macOSInfoRow(
                    title: LocalizationManager.shared.localizedString("qrcode.serviceStatus"),
                    value: isServerRunning ? LocalizationManager.shared.localizedString("status.running") : LocalizationManager.shared.localizedString("status.stopped"),
                    icon: isServerRunning ? "checkmark.circle.fill" : "xmark.circle.fill",
                    statusColor: isServerRunning ? .green : .red
                )
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private var fileListCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.orange)
                    .font(.title3)

                Text(LocalizationManager.shared.localizedString("qrcode.pendingFiles"))
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                Text(String(format: LocalizationManager.shared.localizedString("common.files.count"), selectedFiles.count))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(selectedFiles, id: \.self) { file in
                        macOSFileRow(file: file)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private var macOSBottomBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)

                Text(LocalizationManager.shared.localizedString("qrcode.networkHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(LocalizationManager.shared.localizedString("action.cancel")) {
                    stopServer()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(isServerRunning ? LocalizationManager.shared.localizedString("action.stopServer") : LocalizationManager.shared.localizedString("action.startServer")) {
                    if isServerRunning {
                        stopServer()
                    } else {
                        Task { await startServer() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.thickMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func macOSInfoRow(
        title: String,
        value: String,
        icon: String,
        isMonospaced: Bool = false,
        isHighlighted: Bool = false,
        statusColor: Color? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(statusColor ?? .accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(value)
                    .font(isMonospaced ? .system(.subheadline, design: .monospaced) : .subheadline)
                    .fontWeight(isHighlighted ? .semibold : .regular)
                    .foregroundColor(isHighlighted ? .accentColor : .primary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func macOSFileRow(file: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconForFile(file))
                .foregroundColor(.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.lastPathComponent)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(formatFileSize(file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func generateConnectionInfo() async {
        do {
            let link = try await TransferLinkManager.shared.createTransferLink(for: selectedFiles)
            currentLink = link
            serverURL = link.shareUrl
            connectionCode = String(link.id.prefix(8)).uppercased()
            isServerRunning = true
            generateQRCode(from: link.shareUrl)
        } catch {
            qrCodeImage = nil
            serverURL = ""
            connectionCode = ""
            isServerRunning = false
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "SkyBridgeCompassApp", category: "ui")
                .error("文件传输链接生成失败: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func generateQRCode(from string: String) {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        guard let data = string.data(using: .utf8) else { return }

        filter.message = data
        filter.correctionLevel = "M"

        if let outputImage = filter.outputImage {
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledImage = outputImage.transformed(by: transform)

            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                qrCodeImage = NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220))
            }
        }
    }

    private func startServer() async {
        guard !isServerRunning else { return }
        await generateConnectionInfo()
    }

    private func stopServer() {
        guard let currentLink else { return }
        let linkID = currentLink.id
        self.currentLink = nil
        qrCodeImage = nil
        serverURL = ""
        connectionCode = ""
        isServerRunning = false
        Task {
            await TransferLinkManager.shared.deleteLink(linkID)
        }
    }

    private func iconForFile(_ file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "svg":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "wmv", "flv":
            return "video"
        case "mp3", "wav", "aac", "flac", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "doc", "docx":
            return "doc.text"
        case "xls", "xlsx":
            return "tablecells"
        case "ppt", "pptx":
            return "rectangle.on.rectangle"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox"
        case "txt", "rtf":
            return "doc.plaintext"
        default:
            return "doc"
        }
    }

    private func formatFileSize(_ file: URL) -> String {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if let fileSize = attributes[.size] as? Int64 {
                return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            }
        } catch {
            SkyBridgeLogger.ui.error("获取文件大小失败: \(error.localizedDescription, privacy: .private)")
        }
        return "未知大小"
    }
}
