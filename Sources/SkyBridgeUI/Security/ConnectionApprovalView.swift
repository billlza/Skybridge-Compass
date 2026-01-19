//
// ConnectionApprovalView.swift
// SkyBridgeUI
//
// 连接审批界面
// 支持 macOS 14.0+
//

import SwiftUI
import SkyBridgeCore

/// 连接审批视图
public struct ConnectionApprovalView: View {

    @ObservedObject private var approvalService: ConnectionApprovalService
    @State private var verificationCode = ""
    @State private var useBiometric = false

    public init(approvalService: ConnectionApprovalService = .shared) {
        self.approvalService = approvalService
    }

    public var body: some View {
        Form {
            // 审批策略
            Section {
                Toggle("启用连接审批", isOn: $approvalService.policy.requireApproval)

                if approvalService.policy.requireApproval {
                    Stepper("必需验证因素: \(approvalService.policy.requiredFactorCount)", value: $approvalService.policy.requiredFactorCount, in: 1...3)

                    Toggle("自动批准受信任设备", isOn: $approvalService.policy.autoApproveTrustedDevices)

                    Picker("请求超时", selection: $approvalService.policy.requestTimeout) {
                        Text("1 分钟").tag(TimeInterval(60))
                        Text("2 分钟").tag(TimeInterval(120))
                        Text("5 分钟").tag(TimeInterval(300))
                    }
                }
            } header: {
                Label("审批策略", systemImage: "shield.checkered")
            }

            // 验证因素
            if approvalService.policy.requireApproval {
                Section {
                    ForEach(VerificationFactor.allCases, id: \.self) { factor in
                        Toggle(isOn: Binding(
                            get: { approvalService.policy.enabledFactors.contains(factor) },
                            set: { enabled in
                                if enabled {
                                    approvalService.policy.enabledFactors.insert(factor)
                                } else if approvalService.policy.enabledFactors.count > 1 {
                                    approvalService.policy.enabledFactors.remove(factor)
                                }
                            }
                        )) {
                            Label(factor.displayName, systemImage: factor.icon)
                        }
                        .disabled(factor == .biometric && !approvalService.biometricAvailable)
                    }
                } header: {
                    Label("验证因素", systemImage: "checkmark.shield")
                }
            }

            // 待处理请求
            Section {
                if approvalService.pendingRequests.isEmpty {
                    Text("暂无待处理的审批请求")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(approvalService.pendingRequests) { request in
                        pendingRequestRow(request)
                    }
                }
            } header: {
                Label("待处理请求 (\(approvalService.pendingRequests.count))", systemImage: "bell.badge")
            }

            // 受信任设备
            Section {
                if approvalService.trustedDevices.isEmpty {
                    Text("暂无受信任设备")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(approvalService.trustedDevices) { device in
                        trustedDeviceRow(device)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let device = approvalService.trustedDevices[index]
                            approvalService.removeTrustedDevice(device.deviceID)
                        }
                    }
                }
            } header: {
                Label("受信任设备 (\(approvalService.trustedDevices.count))", systemImage: "checkmark.seal")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Subviews

    private func pendingRequestRow(_ request: ConnectionApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 设备信息
            HStack {
                Image(systemName: request.requestingDeviceType.icon)
                    .font(.title2)
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(request.requestingDeviceName)
                        .font(.headline)

                    Text(request.requestingDeviceType.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // 剩余时间
                VStack(alignment: .trailing) {
                    Text(formatRemainingTime(request.remainingTime))
                        .font(.caption)
                        .foregroundColor(request.remainingTime < 30 ? .red : .secondary)

                    if request.remainingTime < 30 {
                        Text("即将过期")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
            }

            // 验证码显示
            HStack {
                Text("验证码:")
                    .foregroundColor(.secondary)

                Text(request.verificationCode)
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.blue)

                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)

            // 操作按钮
            HStack(spacing: 12) {
                if approvalService.biometricAvailable && approvalService.policy.enabledFactors.contains(.biometric) {
                    Button {
                        Task {
                            try? await approvalService.approveRequest(request.id, useBiometric: true)
                        }
                    } label: {
                        Label("Touch ID 批准", systemImage: "touchid")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    Task {
                        try? await approvalService.approveRequest(request.id, verificationCode: request.verificationCode)
                    }
                } label: {
                    Label("批准", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    Task {
                        try? await approvalService.rejectRequest(request.id)
                    }
                } label: {
                    Label("拒绝", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
    }

    private func trustedDeviceRow(_ device: ApprovalTrustedDevice) -> some View {
        HStack {
            Image(systemName: device.deviceType.icon)
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName)
                    .font(.body)

                HStack {
                    Text(device.trustLevel.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(trustLevelColor(device.trustLevel).opacity(0.2))
                        .foregroundColor(trustLevelColor(device.trustLevel))
                        .cornerRadius(4)

                    Text("添加于 \(device.trustedAt, style: .date)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // 信任级别选择
            Menu {
                ForEach([ApprovalTrustLevel.temporary, .standard, .elevated], id: \.self) { level in
                    Button {
                        approvalService.updateTrustLevel(device.deviceID, level: level)
                    } label: {
                        HStack {
                            Text(level.displayName)
                            if device.trustLevel == level {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func formatRemainingTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func trustLevelColor(_ level: ApprovalTrustLevel) -> Color {
        switch level {
        case .temporary: return .orange
        case .standard: return .blue
        case .elevated: return .green
        }
    }
}

// MARK: - 审批请求弹窗

/// 审批请求弹窗视图
public struct ApprovalRequestAlertView: View {
    let request: ConnectionApprovalRequest
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var timeRemaining: TimeInterval

    public init(
        request: ConnectionApprovalRequest,
        onApprove: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) {
        self.request = request
        self.onApprove = onApprove
        self.onReject = onReject
        self._timeRemaining = State(initialValue: request.remainingTime)
    }

    public var body: some View {
        VStack(spacing: 16) {
            // 图标
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            // 标题
            Text("连接请求")
                .font(.headline)

            // 设备信息
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: request.requestingDeviceType.icon)
                    Text(request.requestingDeviceName)
                        .fontWeight(.medium)
                }

                Text("请求连接到您的设备")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 验证码
            VStack(spacing: 4) {
                Text("验证码")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(request.verificationCode)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundColor(.blue)
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(12)

            // 剩余时间
            Text("剩余时间: \(Int(timeRemaining)) 秒")
                .font(.caption)
                .foregroundColor(timeRemaining < 30 ? .red : .secondary)

            // 按钮
            HStack(spacing: 16) {
                Button(role: .destructive, action: onReject) {
                    Text("拒绝")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onApprove) {
                    Text("批准")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 320)
        .task {
            while timeRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                timeRemaining = max(0, timeRemaining - 1)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ConnectionApprovalView_Previews: PreviewProvider {
    static var previews: some View {
        ConnectionApprovalView()
            .frame(width: 500, height: 700)
    }
}
#endif
