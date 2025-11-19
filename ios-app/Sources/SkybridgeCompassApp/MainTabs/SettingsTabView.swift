import SwiftUI
import SettingsKit
import QuantumSecurityKit
import SkyBridgeDesignSystem

struct SettingsTabView: View {
    @State private var performanceState: PerformanceSettings
    @State private var securityState: QuantumSecurityStatus

    init(performance: PerformanceSettings, security: QuantumSecurityStatus) {
        _performanceState = State(initialValue: performance)
        _securityState = State(initialValue: security)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                performancePanel
                securityPanel
                networkPanel
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 220)
        }
        .overlay(alignment: .bottom) {
            LiquidBottomBar {
                VStack(alignment: .leading, spacing: 12) {
                    Text("设置操作")
                        .font(.headline)
                    HStack(spacing: 12) {
                        PrimaryActionButton(title: "保存配置", icon: "checkmark.circle") {}
                        PrimaryActionButton(title: "重置", icon: "arrow.uturn.backward") {
                            performanceState = .default
                            securityState = .default
                        }
                    }
                }
            }
        }
    }

    private var performancePanel: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("性能模式", systemImage: "speedometer")
                    .font(.headline)
                Picker("性能模式", selection: $performanceState.mode) {
                    ForEach(PerformanceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading) {
                    Text("渲染倍率 \(Int(performanceState.renderScale * 100))%")
                        .font(.subheadline)
                    Slider(value: $performanceState.renderScale, in: 0.4...1.0)
                }
                HStack {
                    Stepper("最大分辨率 \(performanceState.maxResolution)", value: $performanceState.maxResolution, in: 2048...12000, step: 256)
                }
                Picker("目标帧率", selection: $performanceState.targetFPS) {
                    ForEach([30, 60, 120], id: \.self) { fps in
                        Text("\(fps) FPS").tag(fps)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var securityPanel: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("量子安全", systemImage: "lock.shield")
                    .font(.headline)
                Toggle("后量子密码", isOn: Binding(
                    get: { securityState.pqcEnabled },
                    set: { securityState = QuantumSecurityStatus(pqcEnabled: $0, tlsHybridEnabled: securityState.tlsHybridEnabled, secureEnclaveSigning: securityState.secureEnclaveSigning, secureEnclaveKEM: securityState.secureEnclaveKEM, algorithm: securityState.algorithm) }
                ))
                Toggle("TLS 混合协商", isOn: Binding(
                    get: { securityState.tlsHybridEnabled },
                    set: { securityState = QuantumSecurityStatus(pqcEnabled: securityState.pqcEnabled, tlsHybridEnabled: $0, secureEnclaveSigning: securityState.secureEnclaveSigning, secureEnclaveKEM: securityState.secureEnclaveKEM, algorithm: securityState.algorithm) }
                ))
                Picker("签名算法", selection: Binding(
                    get: { securityState.algorithm },
                    set: { securityState = QuantumSecurityStatus(pqcEnabled: securityState.pqcEnabled, tlsHybridEnabled: securityState.tlsHybridEnabled, secureEnclaveSigning: securityState.secureEnclaveSigning, secureEnclaveKEM: securityState.secureEnclaveKEM, algorithm: $0) }
                )) {
                    ForEach(PQCAlgorithm.allCases, id: \.self) { algo in
                        Text(algo.rawValue).tag(algo)
                    }
                }
                Toggle("ML-DSA 使用 Secure Enclave", isOn: Binding(
                    get: { securityState.secureEnclaveSigning },
                    set: { securityState = QuantumSecurityStatus(pqcEnabled: securityState.pqcEnabled, tlsHybridEnabled: securityState.tlsHybridEnabled, secureEnclaveSigning: $0, secureEnclaveKEM: securityState.secureEnclaveKEM, algorithm: securityState.algorithm) }
                ))
                Toggle("ML-KEM 使用 Secure Enclave", isOn: Binding(
                    get: { securityState.secureEnclaveKEM },
                    set: { securityState = QuantumSecurityStatus(pqcEnabled: securityState.pqcEnabled, tlsHybridEnabled: securityState.tlsHybridEnabled, secureEnclaveSigning: securityState.secureEnclaveSigning, secureEnclaveKEM: $0, algorithm: securityState.algorithm) }
                ))
            }
        }
    }

    private var networkPanel: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("网络与实验", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Toggle("启用 IPv6", isOn: $performanceState.enableIPv6)
                Toggle("新发现算法", isOn: $performanceState.enableNewDiscovery)
                Toggle("启用 P2P 直连", isOn: $performanceState.enableP2P)
                Stepper("最大并发 \(performanceState.maxConcurrentLinks)", value: $performanceState.maxConcurrentLinks, in: 1...12)
                VStack(alignment: .leading) {
                    Text("设备强度平滑 \(String(format: "%.2f", performanceState.smoothing))")
                    Slider(value: $performanceState.smoothing, in: 0...1)
                }
            }
        }
    }
}
