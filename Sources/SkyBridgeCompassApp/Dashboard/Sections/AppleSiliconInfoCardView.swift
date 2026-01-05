import SwiftUI
import SkyBridgeCore

/// Apple Silicon系统信息卡片
@available(macOS 14.0, *)
public struct AppleSiliconInfoCardView: View {
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    
    private var optimizer: AppleSiliconOptimizer? {
        return AppleSiliconOptimizer.shared
    }
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(LocalizationManager.shared.localizedString("dashboard.systemPerformance"), systemImage: "cpu.fill")
                    .font(.headline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 12) {
                if let optimizer = optimizer {
                    let systemInfo = optimizer.getSystemInfo()
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizationManager.shared.localizedString("info.processorArch"))
                                .font(.caption)
                                .foregroundColor(themeConfiguration.secondaryTextColor)
 // 专为 Apple Silicon 设计
                            if optimizer.isAppleSilicon {
                                Text(LocalizationManager.shared.localizedString("info.appleSilicon"))
                                    .font(.title3.bold())
                                    .foregroundColor(.green)
                            } else {
 // 应用专为 Apple Silicon 设计
                                Text(LocalizationManager.shared.localizedString("info.reqAppleSilicon"))
                                    .font(.title3.bold())
                                    .foregroundColor(.red)
                            }
                        }
                        
                        Spacer()
                        
                        if optimizer.isAppleSilicon {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.yellow)
                                    .font(.caption)
                                Text(LocalizationManager.shared.localizedString("info.optimizationEnabled"))
                                    .font(.caption)
                                    .foregroundColor(.yellow)
                            }
                        } else {
 // 显示不支持的设备警告
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption)
                                Text(LocalizationManager.shared.localizedString("info.deviceUnsupported"))
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    
                    if optimizer.isAppleSilicon {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizationManager.shared.localizedString("info.pCore"))
                                    .font(.caption)
                                    .foregroundColor(themeConfiguration.secondaryTextColor)
                                Text("\(systemInfo.performanceCoreCount)")
                                    .font(.title3.bold())
                                    .foregroundColor(.blue)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizationManager.shared.localizedString("info.eCore"))
                                    .font(.caption)
                                    .foregroundColor(themeConfiguration.secondaryTextColor)
                                Text("\(systemInfo.efficiencyCoreCount)")
                                    .font(.title3.bold())
                                    .foregroundColor(.green)
                            }
                        
                            Spacer()
                        }
                    }
                    
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text(LocalizationManager.shared.localizedString("info.multiCoreOpt"))
                            .font(.caption)
                            .foregroundColor(themeConfiguration.secondaryTextColor)
                    }
                } else {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(LocalizationManager.shared.localizedString("info.standardMode"))
                            .font(.caption)
                            .foregroundColor(themeConfiguration.secondaryTextColor)
                    }
                }
            }
        }
        .padding(20)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
}

