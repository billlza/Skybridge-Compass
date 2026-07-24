import SwiftUI

@available(iOS 17.0, *)
struct InboundFileTransferApprovalView: View {
    let pendingRequest: InboundFileTransferApprovalService.PendingRequest
    let onApprove: () -> Void
    let onReject: () -> Void

    private var request: CrossNetworkWebRTCManager.InboundFileTransferApprovalRequest {
        pendingRequest.request
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("发送方") {
                    LabeledContent("设备", value: request.senderDeviceName)
                }

                Section("文件") {
                    LabeledContent("名称", value: request.fileName)
                    LabeledContent(
                        "大小",
                        value: ByteCountFormatter.string(
                            fromByteCount: request.fileSize,
                            countStyle: .file
                        )
                    )
                }

                Section {
                    Text("仅在你认识该设备并确认正在等待此文件时接受。文件内容在保存前仍会进行完整性校验。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("接收文件？")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("拒绝", role: .cancel, action: onReject)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("接受", action: onApprove)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
