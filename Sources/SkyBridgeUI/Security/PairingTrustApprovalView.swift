import SwiftUI
import SkyBridgeCore

/// UI sheet shown when a peer requests pairing/trust bootstrap (KEM identity exchange).
@available(macOS 14.0, *)
public struct PairingTrustApprovalSheet: View {
    public let request: PairingTrustApprovalService.Request
    public let onDecision: (PairingTrustApprovalService.Decision) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    public init(
        request: PairingTrustApprovalService.Request,
        onDecision: @escaping (PairingTrustApprovalService.Decision) -> Void
    ) {
        self.request = request
        self.onDecision = onDecision
    }
    
    public var body: some View {
        NavigationStack {
            List {
                Section("设备信息") {
                    LabeledContent("名称", value: request.displayName)
                    if let platform = request.platform, !platform.isEmpty {
                        LabeledContent("平台", value: platform)
                    }
                    if let model = request.model, !model.isEmpty {
                        LabeledContent("型号", value: model)
                    }
                    if let os = request.osVersion, !os.isEmpty {
                        LabeledContent("系统", value: os)
                    }
                }
                
                Section("识别信息") {
                    LabeledContent("Device ID", value: request.declaredDeviceId)
                    LabeledContent("Endpoint", value: request.peerEndpoint)
                    LabeledContent("KEM Keys", value: "\(request.kemKeyCount)")
                }
                
                Section {
                    Button {
                        onDecision(.alwaysAllow)
                        dismiss()
                    } label: {
                        Text("始终允许")
                    }
                    
                    Button {
                        onDecision(.allowOnce)
                        dismiss()
                    } label: {
                        Text("允许本次")
                    }
                    
                    Button(role: .destructive) {
                        onDecision(.reject)
                        dismiss()
                    } label: {
                        Text("拒绝")
                    }
                } footer: {
                    Text("该申请用于建立/更新 PQC 引导所需的 KEM 身份公钥信任信息。选择“始终允许”会记住该设备。")
                }
            }
            .navigationTitle("受信任申请")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}


