import SwiftUI
import SkyBridgeCore

/// UI sheet shown when a peer requests pairing/trust bootstrap (KEM identity exchange).
@available(macOS 14.0, *)
public struct PairingTrustApprovalSheet: View {
    public let request: PairingTrustApprovalService.Request
    public let onDecision: (PairingTrustApprovalService.Decision) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = PairingTrustApprovalService.shared
    
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

                    if shouldShowVerificationStage {
                        Section("验证码（用于 iOS PQC 身份验证）") {
                            if let code = service.pendingVerificationCode, !code.isEmpty {
                                LabeledContent("6 位验证码") {
                                    Text(code)
                                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                                        .textSelection(.enabled)
                                }

                                if let suite = service.pendingVerificationSuite, !suite.isEmpty {
                                    LabeledContent("Suite", value: suite)
                                }
                            } else {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("等待完成重握手并生成验证码…")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
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
                        if let algorithm = request.protocolIdentityAlgorithm, !algorithm.isEmpty {
                            LabeledContent("协议签名算法", value: algorithm)
                        }
                        if let fingerprint = request.protocolIdentityFingerprint, !fingerprint.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("协议身份指纹")
                                    .foregroundStyle(.secondary)
                                Text(fingerprint)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        LabeledContent("KEM Keys", value: "\(request.kemKeyCount)")
                    }
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 10) {
                    if shouldShowCompletionOnly {
                        Text(completionText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Spacer(minLength: 0)
                            Button {
                                service.userDismissedCurrentPrompt()
                                dismiss()
                            } label: {
                                Text("完成")
                                    .frame(minWidth: 90)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Text(promptText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if service.isPendingResolutionInFlight {
                            ProgressView("正在安全写入协议身份信任…")
                                .controlSize(.small)
                        }

                        if let notice = service.pendingResolutionNotice {
                            Label(notice, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        
                        HStack(spacing: 10) {
                            Button(role: .destructive) {
                                resolve(.reject)
                            } label: {
                                Text("拒绝")
                                    .frame(minWidth: 76)
                            }
                            .disabled(decisionControlsDisabled)
                            
                            Spacer(minLength: 0)
                            
                            Button {
                                resolve(.allowOnce)
                            } label: {
                                Text("允许本次")
                                    .frame(minWidth: 90)
                            }
                            .buttonStyle(.bordered)
                            .disabled(decisionControlsDisabled)
                            
                            Button {
                                resolve(.alwaysAllow)
                            } label: {
                                Text("始终允许")
                                    .frame(minWidth: 90)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(decisionControlsDisabled)
                        }
                    }
                }
                .padding(16)
                .background(.regularMaterial)
            }
            .navigationTitle("受信任申请")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        service.userDismissedCurrentPrompt()
                        dismiss()
                    } label: {
                        Text("关闭")
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(service.isPendingResolutionInFlight)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .interactiveDismissDisabled(service.isPendingResolutionInFlight)
    }
    
    private var shouldShowVerificationStage: Bool {
        guard service.pendingRequest?.id == request.id else { return false }
        if isProtocolIdentityBindingPrompt {
            return service.pendingVerificationCode?.isEmpty == false
        }
        guard let decision = service.pendingDecision else { return false }
        return decision != .reject
    }

    private var shouldShowCompletionOnly: Bool {
        guard shouldShowVerificationStage else { return false }
        guard service.pendingDecision != nil else { return false }
        return true
    }

    private var isProtocolIdentityBindingPrompt: Bool {
        if service.pendingVerificationSuite == "PIB-1" {
            return true
        }
        return request.policyBindingKey?.hasPrefix("PIB-1") == true
    }

    private var promptText: String {
        if isProtocolIdentityBindingPrompt {
            return "请确认 Mac 与 iPhone/iPad 显示的 6 位验证码完全一致；一致后才允许建立协议身份 pin。"
        }
        return "该申请用于建立/更新 PQC 引导所需的 KEM 身份公钥信任信息。选择“始终允许”会记住该设备。"
    }

    private var completionText: String {
        if service.pendingResolutionNotice != nil {
            return "协议身份已为本次连接完成确认；永久允许策略未保存，下次仍需再次核对。"
        }
        if service.pendingVerificationSuite == "PIB-1-v3-candidate" {
            return "候选身份尚未获得授权。请在另一端显示同一验证码并批准；收到签名确认后，本机还会要求你显式批准，之后才会写入信任。"
        }
        if isProtocolIdentityBindingPrompt {
            return "协议身份确认已处理。另一端现在可以继续 SKR-1 signed KEM refresh。"
        }
        return "请将上方 6 位验证码输入到 iPhone/iPad 的“PQC 身份验证”界面，以完成论文叙事中的 OOB pairing ceremony。"
    }

    private func resolve(_ decision: PairingTrustApprovalService.Decision) {
        guard !decisionControlsDisabled else { return }
        onDecision(decision)
        // Sheet dismissal is driven by `pendingRequest`. For allow decisions we keep the sheet open
        // to surface the transcript-bound SAS verification code.
    }

    private var decisionControlsDisabled: Bool {
        service.pendingDecision != nil || service.isPendingResolutionInFlight
    }
}
