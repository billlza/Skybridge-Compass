import SwiftUI
import SkyBridgeCore

/// UI sheet shown when a peer requests pairing/trust bootstrap (KEM identity exchange).
@available(macOS 14.0, *)
public struct PairingTrustApprovalSheet: View {
    public let request: PairingTrustApprovalService.Request
    public let onDecision: (PairingTrustApprovalService.Decision) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var isResolving: Bool = false
    
    public init(
        request: PairingTrustApprovalService.Request,
        onDecision: @escaping (PairingTrustApprovalService.Decision) -> Void
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
                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(width: 42, height: 42)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.displayName)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text("请求建立/更新 PQC 引导信任（KEM 身份公钥）")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    Section("设备信息") {
                        LabeledContent("平台", value: (request.platform?.isEmpty == false ? request.platform! : "未知"))
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
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("该申请用于建立/更新 PQC 引导所需的 KEM 身份公钥信任信息。选择“始终允许”会记住该设备。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 10) {
                        Button(role: .destructive) {
                            resolve(.reject)
                        } label: {
                            Text("拒绝")
                                .frame(minWidth: 76)
                        }
                        .disabled(isResolving)
                        
                        Spacer(minLength: 0)
                        
                        Button {
                            resolve(.allowOnce)
                        } label: {
                            Text("允许本次")
                                .frame(minWidth: 90)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isResolving)
                        
                        Button {
                            resolve(.alwaysAllow)
                        } label: {
                            Text("始终允许")
                                .frame(minWidth: 90)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(isResolving)
                    }
                }
                .padding(16)
                .background(.regularMaterial)
            }
            .navigationTitle("受信任申请")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("关闭")
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }
    
    private func resolve(_ decision: PairingTrustApprovalService.Decision) {
        guard !isResolving else { return }
        isResolving = true
        onDecision(decision)
        dismiss()
    }
}



