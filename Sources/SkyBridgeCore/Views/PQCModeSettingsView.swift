#if os(macOS)
import SwiftUI
import SkyBridgeProtocolCore

/// Both settings surfaces use the same policy owner and native configuration transaction.
@MainActor
public struct PQCModeSettingsView: View {
    @ObservedObject private var settingsManager: SettingsManager

    public init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("自动选择（推荐）", isOn: Binding(
                get: { !settingsManager.strictlyMatchSelectedPQCMode },
                set: { automatic in
                    do {
                        try settingsManager.setStrictlyMatchSelectedPQCMode(
                            !automatic, isBusy: NativeHandshakeConfiguration.isBusy
                        )
                    } catch { settingsManager.reportPQCModePolicyError(error) }
                }
            ))
            .disabled(settingsManager.applyingHandshakeProfile)
            Text("自动选择双方支持的安全连接方式，通常无需调整。关闭后可指定算法。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settingsManager.strictlyMatchSelectedPQCMode {
                Picker("指定算法（高级）", selection: Binding<HandshakeProfile>(
                    get: {
                        settingsManager.preferQPeriaptBeta ? .qperiapt
                            : (settingsManager.preferXWingHybrid ? .xwing : .mlkem)
                    },
                    set: { profile in
                        Task { @MainActor in
                            do {
                                let current = try NativeHandshakeConfiguration.snapshot()
                                _ = try await NativeHandshakeConfiguration.apply(profile, revision: current.revision)
                            } catch { settingsManager.reportPQCModePolicyError(error) }
                        }
                    }
                )) {
                    Text("Q-Periapt ABI2（Beta）").tag(HandshakeProfile.qperiapt)
                    Text("X-Wing").tag(HandshakeProfile.xwing)
                    Text("ML-KEM-768").tag(HandshakeProfile.mlkem)
                }
                .disabled(settingsManager.applyingHandshakeProfile)
                Text("仅允许指定算法；另一台设备不支持时会停止连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = settingsManager.pqcModePolicyError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let error = settingsManager.qPeriaptRuntimePreparationError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("重试 Q-Periapt 准备") {
                    settingsManager.retryQPeriaptRuntimePreparation()
                }
                .disabled(settingsManager.isPreparingQPeriaptRuntime)
            }

            DisclosureGroup("算法与兼容性") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("自动模式按已验证的共同能力依次选择 Q-Periapt、X-Wing、ML-KEM。Q-Periapt 还要求双方已认证策略一致。")
                    Text("没有共同的后量子算法时会停止连接，不会自动改为经典算法。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
