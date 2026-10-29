import SwiftUI
import SkyBridgeCore

@available(macOS 14.0, *)
public struct InboundFileTransferApprovalSheet: View {
    public let request: InboundFileTransferApprovalService.Request
    public let onDecision: (InboundFileTransferApprovalService.Decision) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = InboundFileTransferApprovalService.shared

    public init(
        request: InboundFileTransferApprovalService.Request,
        onDecision: @escaping (InboundFileTransferApprovalService.Decision) -> Void
    ) {
        self.request = request
        self.onDecision = onDecision
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        HStack(alignment: .center, spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(width: 42, height: 42)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.fileName)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(request.senderDeviceName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }

                    Section("文件") {
                        LabeledContent("名称", value: request.fileName)
                        LabeledContent("大小", value: formattedFileSize)
                        LabeledContent("分块", value: "\(request.totalChunks)")
                    }

                    Section("来源") {
                        LabeledContent("设备", value: request.senderDeviceName)
                        LabeledContent("Device ID", value: request.senderDeviceId)
                        LabeledContent("Endpoint", value: request.endpointDescription)
                    }

                    Section("保存位置") {
                        LabeledContent("目录", value: request.destinationDirectoryPath)
                        LabeledContent("文件", value: request.proposedSavePath)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("只允许本次接收；设备信任状态不会自动授权文件写入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button(role: .destructive) {
                            resolve(.reject)
                        } label: {
                            Text("拒绝")
                                .frame(minWidth: 76)
                        }

                        Spacer(minLength: 0)

                        Button {
                            resolve(.allowOnce)
                        } label: {
                            Text("允许接收")
                                .frame(minWidth: 92)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .background(.regularMaterial)
            }
            .navigationTitle("接收文件")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        service.userDismissedCurrentPrompt()
                        dismiss()
                    } label: {
                        Text("关闭")
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: request.fileSize)
    }

    private func resolve(_ decision: InboundFileTransferApprovalService.Decision) {
        onDecision(decision)
    }
}
