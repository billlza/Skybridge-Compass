import SwiftUI

/// PQC 验证视图 - 验证设备的后量子加密身份
@available(iOS 17.0, *)
struct PQCVerificationView: View {
    let device: DiscoveredDevice
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pqcManager = PQCCryptoManager.instance
    
    @State private var verificationCode = ""
    @State private var isVerifying = false
    @State private var verificationStep: VerificationStep = .introduction
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient
                
                ScrollView {
                    VStack(spacing: 32) {
                        // 进度指示器
                        progressIndicator
                        
                        // 当前步骤内容
                        currentStepContent
                        
                        // 操作按钮
                        actionButton
                    }
                    .padding()
                }
            }
            .navigationTitle("PQC 身份验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .alert("验证失败", isPresented: $showError) {
                Button("重试", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.05, blue: 0.15),
                Color(red: 0.1, green: 0.1, blue: 0.2)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    // MARK: - Progress Indicator
    
    private var progressIndicator: some View {
        HStack(spacing: 0) {
            ForEach(VerificationStep.allCases.indices, id: \.self) { index in
                let step = VerificationStep.allCases[index]
                
                HStack(spacing: 0) {
                    // 步骤圆圈
                    Circle()
                        .fill(stepColor(for: step))
                        .frame(width: 30, height: 30)
                        .overlay(
                            Group {
                                if verificationStep.rawValue > step.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                } else {
                                    Text("\(index + 1)")
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                }
                            }
                        )
                    
                    // 连接线（除了最后一个）
                    if index < VerificationStep.allCases.count - 1 {
                        Rectangle()
                            .fill(lineColor(from: step))
                            .frame(height: 2)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal)
    }
    
    private func stepColor(for step: VerificationStep) -> Color {
        if verificationStep.rawValue >= step.rawValue {
            return .blue
        } else {
            return Color.gray.opacity(0.3)
        }
    }
    
    private func lineColor(from step: VerificationStep) -> Color {
        if verificationStep.rawValue > step.rawValue {
            return .blue
        } else {
            return Color.gray.opacity(0.3)
        }
    }
    
    // MARK: - Step Content
    
    @ViewBuilder
    private var currentStepContent: some View {
        switch verificationStep {
        case .introduction:
            introductionContent
        case .keyExchange:
            keyExchangeContent
        case .codeVerification:
            codeVerificationContent
        case .completed:
            completedContent
        }
    }
    
    private var introductionContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green.gradient)
            
            Text("后量子加密验证")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            Text("使用 NIST 标准的后量子密码算法确保设备身份的真实性和安全性")
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "key.fill", title: "ML-KEM-768", description: "密钥封装")
                FeatureRow(icon: "signature", title: "ML-DSA-65", description: "数字签名")
                FeatureRow(icon: "shield.lefthalf.filled", title: "X-Wing", description: "混合加密")
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(16)
        }
    }
    
    private var keyExchangeContent: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.blue)
            
            Text("正在交换密钥...")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("使用 ML-KEM-768 进行后量子密钥交换")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            
            VStack(spacing: 8) {
                InfoRow(label: "本地公钥", value: "已生成")
                InfoRow(label: "远程公钥", value: "已接收")
                InfoRow(label: "共享密钥", value: "计算中...")
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
        }
        .onAppear {
            performKeyExchange()
        }
    }
    
    private var codeVerificationContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "numbersign")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("验证码确认")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            Text("请在 \(device.name) 上查看并输入显示的 6 位验证码")
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            // 验证码输入
            HStack(spacing: 12) {
                ForEach(0..<6) { index in
                    TextField("", text: codeBinding(for: index))
                        .font(.title.bold())
                        .frame(width: 40, height: 50)
                        .multilineTextAlignment(.center)
                        .keyboardType(.numberPad)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                        .foregroundColor(.white)
                        .onChange(of: verificationCode) { _, newValue in
                            if newValue.count == 6 {
                                verifyCode()
                            }
                        }
                }
            }
            
            if isVerifying {
                ProgressView()
                    .tint(.blue)
                    .padding(.top)
            }
        }
    }
    
    private var completedContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green.gradient)
            
            Text("验证成功！")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            Text("\(device.name) 已被添加到受信任设备列表")
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            VStack(spacing: 12) {
                InfoRow(label: "设备名称", value: device.name)
                InfoRow(label: "加密方式", value: "PQC (ML-KEM-768)")
                InfoRow(label: "验证时间", value: Date().formatted())
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
        }
    }
    
    // MARK: - Action Button
    
    private var actionButton: some View {
        Group {
            switch verificationStep {
            case .introduction:
                Button(action: startVerification) {
                    Label("开始验证", systemImage: "arrow.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue.gradient)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                
            case .keyExchange:
                EmptyView()
                
            case .codeVerification:
                EmptyView()
                
            case .completed:
                Button(action: { dismiss() }) {
                    Label("完成", systemImage: "checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.green.gradient)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func codeBinding(for index: Int) -> Binding<String> {
        Binding(
            get: {
                if index < verificationCode.count {
                    return String(verificationCode[verificationCode.index(verificationCode.startIndex, offsetBy: index)])
                }
                return ""
            },
            set: { newValue in
                if newValue.count == 1 && newValue.allSatisfy(\.isNumber) {
                    if index < 6 {
                        var code = verificationCode
                        if index < code.count {
                            let stringIndex = code.index(code.startIndex, offsetBy: index)
                            code.replaceSubrange(stringIndex...stringIndex, with: newValue)
                        } else {
                            code.append(newValue)
                        }
                        verificationCode = code
                    }
                }
            }
        )
    }
    
    // MARK: - Actions
    
    private func startVerification() {
        withAnimation {
            verificationStep = .keyExchange
        }
    }
    
    private func performKeyExchange() {
        Task { @MainActor in
            do {
                // 1) 建立连接 + 完成一次握手（如果缺少 peer KEM keys，可能会 classic fallback）
                try await P2PConnectionManager.instance.connect(to: device)
                
                // 2) 通过已建立的会话加密通道交换 KEM identity 公钥（bootstrap trust store）
                try await P2PConnectionManager.instance.sendPairingIdentityExchange(to: device.id)
                try? await Task.sleep(for: .milliseconds(400)) // 等待对端回包并写入 KEMTrustStore
                
                // 3) 立刻 rekey：preferPQC=true（此时 initiator 已具备 peer KEM public key）
                try await P2PConnectionManager.instance.rekeyToPreferPQC(deviceId: device.id)
                
                withAnimation {
                    verificationStep = .codeVerification
                }
            } catch {
                errorMessage = "密钥交换失败：\(error.localizedDescription)"
                showError = true
                withAnimation {
                    verificationStep = .introduction
                }
            }
        }
    }
    
    private func verifyCode() {
        isVerifying = true
        
        Task {
            do {
                // 验证 PQC 签名和验证码
                try await pqcManager.verifyDevice(device, code: verificationCode)
                
                await MainActor.run {
                    withAnimation {
                        verificationStep = .completed
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "验证码错误，请重试"
                    showError = true
                    verificationCode = ""
                }
            }
            
            isVerifying = false
        }
    }
}

// MARK: - Verification Step

enum VerificationStep: Int, CaseIterable {
    case introduction = 0
    case keyExchange = 1
    case codeVerification = 2
    case completed = 3
}

// MARK: - Feature Row

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.blue)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
        }
    }
}

// MARK: - Preview
#if DEBUG
struct PQCVerificationView_Previews: PreviewProvider {
    static var previews: some View {
        PQCVerificationView(
            device: DiscoveredDevice(
                id: "preview",
                name: "MacBook Pro",
                modelName: "MacBook Pro 16-inch",
                platform: .macOS,
                osVersion: "macOS 26.2",
                ipAddress: "192.168.1.100",
                signalStrength: -45
            )
        )
    }
}
#endif
