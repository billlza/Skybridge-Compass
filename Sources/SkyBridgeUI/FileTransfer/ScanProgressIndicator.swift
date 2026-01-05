//
// ScanProgressIndicator.swift
// SkyBridgeUI
//
// 扫描进度指示器组件 - 显示文件安全扫描进度
// Requirements: 4.1, 4.4
//

import SwiftUI
import SkyBridgeCore

/// 扫描进度指示器 - 显示当前扫描阶段和进度
/// Requirements: 4.1 - 显示扫描指示器和当前扫描阶段
/// Requirements: 4.4 - 显示批量扫描的聚合进度
public struct ScanProgressIndicator: View {
    
 /// 扫描进度数据
    public let progress: FileScanProgress
    
 /// 是否显示详细信息
    public var showDetails: Bool = true
    
 /// 是否使用紧凑布局
    public var compact: Bool = false
    
    @State private var isAnimating = false
    
    public init(progress: FileScanProgress, showDetails: Bool = true, compact: Bool = false) {
        self.progress = progress
        self.showDetails = showDetails
        self.compact = compact
    }
    
    public var body: some View {
        if compact {
            compactView
        } else {
            fullView
        }
    }
    
 // MARK: - Full View
    
    private var fullView: some View {
        VStack(alignment: .leading, spacing: 12) {
 // 标题行
            HStack {
                phaseIcon
                    .font(.title2)
                    .foregroundColor(phaseColor)
                    .scaleEffect(isAnimating ? 1.1 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: isAnimating
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(phaseTitle)
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    if showDetails, let currentFile = progress.currentFile {
                        Text(currentFile.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
 // 进度百分比
                Text("\(Int(progress.overallProgress * 100))%")
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(phaseColor)
                    .contentTransition(.numericText())
            }
            
 // 进度条
            ProgressView(value: progress.overallProgress)
                .tint(phaseColor)
                .animation(.easeInOut(duration: 0.3), value: progress.overallProgress)
            
 // 文件计数
            if showDetails && progress.totalFiles > 1 {
                HStack {
                    Text(LocalizationManager.shared.localizedString("scan.filesProgress"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(progress.completedFiles)/\(progress.totalFiles)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .contentTransition(.numericText())
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(phaseColor.opacity(0.3), lineWidth: 1)
        )
        .onAppear {
            isAnimating = true
        }
    }
    
 // MARK: - Compact View
    
    private var compactView: some View {
        HStack(spacing: 8) {
            phaseIcon
                .font(.caption)
                .foregroundColor(phaseColor)
                .scaleEffect(isAnimating ? 1.1 : 1.0)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: isAnimating
                )
            
            Text(phaseTitle)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text("\(Int(progress.overallProgress * 100))%")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(phaseColor)
                .contentTransition(.numericText())
        }
        .onAppear {
            isAnimating = true
        }
    }
    
 // MARK: - Properties
    
    private var phaseIcon: Image {
        switch progress.currentPhase {
        case .preparing:
            return Image(systemName: "hourglass")
        case .quarantineCheck:
            return Image(systemName: "shield.lefthalf.filled")
        case .xprotectScan:
            return Image(systemName: "shield.checkered")
        case .codeSignatureVerify:
            return Image(systemName: "signature")
        case .notarizationCheck:
            return Image(systemName: "checkmark.seal")
        case .patternMatching:
            return Image(systemName: "magnifyingglass")
        case .heuristicAnalysis:
            return Image(systemName: "brain")
        case .completing:
            return Image(systemName: "checkmark.circle")
        }
    }
    
    private var phaseTitle: String {
        switch progress.currentPhase {
        case .preparing:
            return LocalizationManager.shared.localizedString("scan.phase.preparing")
        case .quarantineCheck:
            return LocalizationManager.shared.localizedString("scan.phase.quarantine")
        case .xprotectScan:
            return LocalizationManager.shared.localizedString("scan.phase.xprotect")
        case .codeSignatureVerify:
            return LocalizationManager.shared.localizedString("scan.phase.signature")
        case .notarizationCheck:
            return LocalizationManager.shared.localizedString("scan.phase.notarization")
        case .patternMatching:
            return LocalizationManager.shared.localizedString("scan.phase.pattern")
        case .heuristicAnalysis:
            return LocalizationManager.shared.localizedString("scan.phase.heuristic")
        case .completing:
            return LocalizationManager.shared.localizedString("scan.phase.completing")
        }
    }
    
    private var phaseColor: Color {
        switch progress.currentPhase {
        case .preparing:
            return .gray
        case .quarantineCheck, .xprotectScan:
            return .blue
        case .codeSignatureVerify, .notarizationCheck:
            return .purple
        case .patternMatching, .heuristicAnalysis:
            return .orange
        case .completing:
            return .green
        }
    }
}

// MARK: - Scan Result Summary View

/// 扫描结果摘要视图 - 用于传输历史
/// Requirements: 4.2 - 显示扫描状态、持续时间和使用的方法
/// Requirements: 7.2 - 在传输历史中显示扫描状态
public struct ScanResultSummaryView: View {
    
    public let result: FileScanResult
    public var compact: Bool = false
    
    public init(result: FileScanResult, compact: Bool = false) {
        self.result = result
        self.compact = compact
    }
    
    public var body: some View {
        if compact {
            compactSummary
        } else {
            fullSummary
        }
    }
    
 // MARK: - Full Summary
    
    private var fullSummary: some View {
        HStack(spacing: 12) {
 // 状态图标
            verdictIcon
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 4) {
 // 状态文本
                Text(verdictText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(verdictColor)
                
 // 扫描详情
                HStack(spacing: 8) {
 // 扫描时长
                    Label(formatDuration(result.scanDuration), systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
 // 使用的方法数
                    Label("\(result.methodsUsed.count)", systemImage: "checklist")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
 // 警告数
                    if !result.warnings.isEmpty {
                        Label("\(result.warnings.count)", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
            
            Spacer()
        }
    }
    
 // MARK: - Compact Summary
    
    private var compactSummary: some View {
        HStack(spacing: 6) {
            verdictIcon
                .font(.caption)
            
            if !result.warnings.isEmpty {
                Text("(\(result.warnings.count))")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }
    
 // MARK: - Verdict Properties
    
    private var verdictIcon: some View {
        Group {
            switch result.verdict {
            case .safe:
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
            case .warning:
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
            case .unsafe:
                Image(systemName: "xmark.shield.fill")
                    .foregroundColor(.red)
            case .unknown:
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.gray)
            }
        }
    }
    
    private var verdictText: String {
        switch result.verdict {
        case .safe:
            return LocalizationManager.shared.localizedString("scan.verdict.safe")
        case .warning:
            return LocalizationManager.shared.localizedString("scan.verdict.warning")
        case .unsafe:
            return LocalizationManager.shared.localizedString("scan.verdict.unsafe")
        case .unknown:
            return LocalizationManager.shared.localizedString("scan.verdict.unknown")
        }
    }
    
    private var verdictColor: Color {
        switch result.verdict {
        case .safe:
            return .green
        case .warning:
            return .orange
        case .unsafe:
            return .red
        case .unknown:
            return .gray
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else {
            return String(format: "%.1fs", duration)
        }
    }
}


// MARK: - Threat Alert Dialog

/// 威胁警报对话框 - 显示检测到的威胁详情和推荐操作
/// Requirements: 4.3 - 显示威胁名称、详情和推荐操作
public struct ThreatAlertDialog: View {
    
    public let result: FileScanResult
    public let onDelete: () -> Void
    public let onQuarantine: () -> Void
    public let onIgnore: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    public init(
        result: FileScanResult,
        onDelete: @escaping () -> Void,
        onQuarantine: @escaping () -> Void,
        onIgnore: @escaping () -> Void
    ) {
        self.result = result
        self.onDelete = onDelete
        self.onQuarantine = onQuarantine
        self.onIgnore = onIgnore
    }
    
    public var body: some View {
        VStack(spacing: 20) {
 // 警告图标
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
            
 // 标题
            Text(LocalizationManager.shared.localizedString("scan.threat.detected"))
                .font(.title2)
                .fontWeight(.bold)
            
 // 文件名
            Text(result.fileURL.lastPathComponent)
                .font(.headline)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            
 // 威胁详情
            if !result.threats.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(result.threats.indices, id: \.self) { index in
                        threatRow(result.threats[index])
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            
 // 警告列表
            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizationManager.shared.localizedString("scan.warnings"))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    ForEach(result.warnings.indices, id: \.self) { index in
                        warningRow(result.warnings[index])
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            
            Divider()
            
 // 推荐操作
            Text(LocalizationManager.shared.localizedString("scan.threat.recommendedActions"))
                .font(.subheadline)
                .foregroundColor(.secondary)
            
 // 操作按钮
            VStack(spacing: 12) {
                Button(action: {
                    onDelete()
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text(LocalizationManager.shared.localizedString("scan.action.delete"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                
                Button(action: {
                    onQuarantine()
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: "lock.shield")
                        Text(LocalizationManager.shared.localizedString("scan.action.quarantine"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button(action: {
                    onIgnore()
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: "hand.raised")
                        Text(LocalizationManager.shared.localizedString("scan.action.ignore"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(minWidth: 400)
    }
    
    private func threatRow(_ threat: ThreatHit) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "virus.fill")
                .foregroundColor(.red)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(threat.signatureName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                HStack(spacing: 8) {
                    Label(threat.category, systemImage: "tag")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Label(String(format: "%.0f%%", threat.confidence * 100), systemImage: "percent")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
    }
    
    private func warningRow(_ warning: ScanWarning) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: severityIcon(warning.severity))
                .foregroundColor(severityColor(warning.severity))
                .font(.caption)
            
            Text(warning.message)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
    
    private func severityIcon(_ severity: ScanWarning.Severity) -> String {
        switch severity {
        case .info:
            return "info.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .critical:
            return "exclamationmark.octagon"
        }
    }
    
    private func severityColor(_ severity: ScanWarning.Severity) -> Color {
        switch severity {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}

// MARK: - Scan Detail Sheet

/// 扫描详情面板 - 显示完整的扫描信息
/// Requirements: 4.5 - 显示所有执行的检查、公证和签名信息、模式匹配计数
public struct ScanDetailSheet: View {
    
    public let result: FileScanResult
    
    @Environment(\.dismiss) private var dismiss
    
    public init(result: FileScanResult) {
        self.result = result
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
 // 文件信息
                    fileInfoSection
                    
                    Divider()
                    
 // 扫描结果摘要
                    scanSummarySection
                    
                    Divider()
                    
 // 执行的检查
                    checksPerformedSection
                    
 // 代码签名信息
                    if let codeSignature = result.codeSignature {
                        Divider()
                        codeSignatureSection(codeSignature)
                    }
                    
 // 公证信息
                    if let notarizationStatus = result.notarizationStatus {
                        Divider()
                        notarizationSection(notarizationStatus)
                    }
                    
 // 威胁详情
                    if !result.threats.isEmpty {
                        Divider()
                        threatsSection
                    }
                    
 // 警告详情
                    if !result.warnings.isEmpty {
                        Divider()
                        warningsSection
                    }
                }
                .padding()
            }
            .navigationTitle(LocalizationManager.shared.localizedString("scan.details.title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationManager.shared.localizedString("common.done")) {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 600)
    }
    
 // MARK: - Sections
    
    private var fileInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LocalizationManager.shared.localizedString("scan.details.fileInfo"), systemImage: "doc")
                .font(.headline)
            
            DetailRow(
                label: LocalizationManager.shared.localizedString("scan.details.fileName"),
                value: result.fileURL.lastPathComponent
            )
            
            DetailRow(
                label: LocalizationManager.shared.localizedString("scan.details.path"),
                value: result.fileURL.path
            )
            
            DetailRow(
                label: LocalizationManager.shared.localizedString("scan.details.targetType"),
                value: targetTypeText(result.targetType)
            )
            
            DetailRow(
                label: LocalizationManager.shared.localizedString("scan.details.scanLevel"),
                value: scanLevelText(result.scanLevel)
            )
        }
    }
    
    private var scanSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LocalizationManager.shared.localizedString("scan.details.summary"), systemImage: "chart.bar")
                .font(.headline)
            
            HStack(spacing: 20) {
 // 裁决
                VStack {
                    verdictIcon
                        .font(.largeTitle)
                    Text(verdictText)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                
 // 扫描时长
                VStack {
                    Text(formatDuration(result.scanDuration))
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(LocalizationManager.shared.localizedString("scan.details.duration"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                
 // 模式匹配数
                VStack {
                    Text("\(result.patternMatchCount)")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(LocalizationManager.shared.localizedString("scan.details.patternsChecked"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
    
    private var checksPerformedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LocalizationManager.shared.localizedString("scan.details.checksPerformed"), systemImage: "checklist")
                .font(.headline)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                ForEach(Array(result.methodsUsed), id: \.self) { method in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text(methodText(method))
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    private func codeSignatureSection(_ signature: CodeSignatureInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LocalizationManager.shared.localizedString("scan.details.codeSignature"), systemImage: "signature")
                .font(.headline)
            
            DetailRow(
                label: LocalizationManager.shared.localizedString("scan.details.signed"),
                value: signature.isSigned ? LocalizationManager.shared.localizedString("common.yes") : LocalizationManager.shared.localizedString("common.no"),
                valueColor: signature.isSigned ? .green : .orange
            )
            
            DetailRow(
                label: LocalizationManager.shared.localizedString("scan.details.valid"),
                value: signature.isValid ? LocalizationManager.shared.localizedString("common.yes") : LocalizationManager.shared.localizedString("common.no"),
                valueColor: signature.isValid ? .green : .red
            )
            
            if let signer = signature.signerIdentity {
                DetailRow(
                    label: LocalizationManager.shared.localizedString("scan.details.signer"),
                    value: signer
                )
            }
            
            if let team = signature.teamIdentifier {
                DetailRow(
                    label: LocalizationManager.shared.localizedString("scan.details.teamId"),
                    value: team
                )
            }
            
            DetailRow(
                label: LocalizationManager.shared.localizedString("scan.details.trustLevel"),
                value: trustLevelText(signature.trustLevel),
                valueColor: trustLevelColor(signature.trustLevel)
            )
        }
    }
    
    private func notarizationSection(_ status: NotarizationStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LocalizationManager.shared.localizedString("scan.details.notarization"), systemImage: "checkmark.seal")
                .font(.headline)
            
            HStack {
                notarizationIcon(status)
                    .font(.title2)
                
                VStack(alignment: .leading) {
                    Text(notarizationText(status))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text(notarizationDescription(status))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(notarizationBackground(status), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    
    private var threatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LocalizationManager.shared.localizedString("scan.details.threats"), systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundColor(.red)
            
            ForEach(result.threats.indices, id: \.self) { index in
                threatDetailRow(result.threats[index])
            }
        }
    }
    
    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LocalizationManager.shared.localizedString("scan.details.warnings"), systemImage: "exclamationmark.circle")
                .font(.headline)
                .foregroundColor(.orange)
            
            ForEach(result.warnings.indices, id: \.self) { index in
                warningDetailRow(result.warnings[index])
            }
        }
    }
    
 // MARK: - Helper Views
    
    private func threatDetailRow(_ threat: ThreatHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "virus.fill")
                    .foregroundColor(.red)
                Text(threat.signatureName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            
            HStack(spacing: 16) {
                Label(threat.category, systemImage: "tag")
                Label(threat.matchType.rawValue, systemImage: "doc.text.magnifyingglass")
                Label(threat.region.rawValue, systemImage: "scope")
                Label(String(format: "%.0f%%", threat.confidence * 100), systemImage: "percent")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
    
    private func warningDetailRow(_ warning: ScanWarning) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: severityIcon(warning.severity))
                .foregroundColor(severityColor(warning.severity))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(warning.code)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                
                Text(warning.message)
                    .font(.subheadline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
    
 // MARK: - Helper Properties
    
    private var verdictIcon: some View {
        Group {
            switch result.verdict {
            case .safe:
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
            case .warning:
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
            case .unsafe:
                Image(systemName: "xmark.shield.fill")
                    .foregroundColor(.red)
            case .unknown:
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.gray)
            }
        }
    }
    
    private var verdictText: String {
        switch result.verdict {
        case .safe:
            return LocalizationManager.shared.localizedString("scan.verdict.safe")
        case .warning:
            return LocalizationManager.shared.localizedString("scan.verdict.warning")
        case .unsafe:
            return LocalizationManager.shared.localizedString("scan.verdict.unsafe")
        case .unknown:
            return LocalizationManager.shared.localizedString("scan.verdict.unknown")
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else {
            return String(format: "%.2fs", duration)
        }
    }
    
    private func targetTypeText(_ type: ScanTargetType) -> String {
        switch type {
        case .file: return LocalizationManager.shared.localizedString("scan.targetType.file")
        case .bundle: return LocalizationManager.shared.localizedString("scan.targetType.bundle")
        case .archive: return LocalizationManager.shared.localizedString("scan.targetType.archive")
        case .directory: return LocalizationManager.shared.localizedString("scan.targetType.directory")
        case .machO: return LocalizationManager.shared.localizedString("scan.targetType.machO")
        case .script: return LocalizationManager.shared.localizedString("scan.targetType.script")
        }
    }
    
    private func scanLevelText(_ level: FileScanService.ScanLevel) -> String {
        switch level {
        case .quick: return LocalizationManager.shared.localizedString("scan.level.quick")
        case .standard: return LocalizationManager.shared.localizedString("scan.level.standard")
        case .deep: return LocalizationManager.shared.localizedString("scan.level.deep")
        }
    }
    
    private func methodText(_ method: ScanMethod) -> String {
        switch method {
        case .quarantine: return LocalizationManager.shared.localizedString("scan.method.quarantine")
        case .gatekeeperAssessment: return LocalizationManager.shared.localizedString("scan.method.gatekeeper")
        case .codeSignature: return LocalizationManager.shared.localizedString("scan.method.codeSignature")
        case .notarization: return LocalizationManager.shared.localizedString("scan.method.notarization")
        case .patternMatch: return LocalizationManager.shared.localizedString("scan.method.patternMatch")
        case .heuristic: return LocalizationManager.shared.localizedString("scan.method.heuristic")
        case .archiveScan: return LocalizationManager.shared.localizedString("scan.method.archiveScan")
        case .xprotect: return LocalizationManager.shared.localizedString("scan.method.xprotect")
        case .signatureCheck: return LocalizationManager.shared.localizedString("scan.method.signatureCheck")
        case .skipped: return LocalizationManager.shared.localizedString("scan.method.skipped")
        }
    }
    
    private func trustLevelText(_ level: CodeSignatureInfo.TrustLevel) -> String {
        switch level {
        case .trusted: return LocalizationManager.shared.localizedString("scan.trustLevel.trusted")
        case .identified: return LocalizationManager.shared.localizedString("scan.trustLevel.identified")
        case .adHoc: return LocalizationManager.shared.localizedString("scan.trustLevel.adHoc")
        case .unsigned: return LocalizationManager.shared.localizedString("scan.trustLevel.unsigned")
        case .invalid: return LocalizationManager.shared.localizedString("scan.trustLevel.invalid")
        }
    }
    
    private func trustLevelColor(_ level: CodeSignatureInfo.TrustLevel) -> Color {
        switch level {
        case .trusted: return .green
        case .identified: return .blue
        case .adHoc: return .orange
        case .unsigned: return .gray
        case .invalid: return .red
        }
    }
    
    private func notarizationIcon(_ status: NotarizationStatus) -> some View {
        Group {
            switch status {
            case .notarized:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
            case .notNotarized:
                Image(systemName: "xmark.seal")
                    .foregroundColor(.orange)
            case .unknown:
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.gray)
            }
        }
    }
    
    private func notarizationText(_ status: NotarizationStatus) -> String {
        switch status {
        case .notarized: return LocalizationManager.shared.localizedString("scan.notarization.notarized")
        case .notNotarized: return LocalizationManager.shared.localizedString("scan.notarization.notNotarized")
        case .unknown: return LocalizationManager.shared.localizedString("scan.notarization.unknown")
        }
    }
    
    private func notarizationDescription(_ status: NotarizationStatus) -> String {
        switch status {
        case .notarized: return LocalizationManager.shared.localizedString("scan.notarization.notarized.desc")
        case .notNotarized: return LocalizationManager.shared.localizedString("scan.notarization.notNotarized.desc")
        case .unknown: return LocalizationManager.shared.localizedString("scan.notarization.unknown.desc")
        }
    }
    
    private func notarizationBackground(_ status: NotarizationStatus) -> Color {
        switch status {
        case .notarized: return .green.opacity(0.1)
        case .notNotarized: return .orange.opacity(0.1)
        case .unknown: return .gray.opacity(0.1)
        }
    }
    
    private func severityIcon(_ severity: ScanWarning.Severity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon"
        }
    }
    
    private func severityColor(_ severity: ScanWarning.Severity) -> Color {
        switch severity {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Detail Row Helper

private struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    
    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(valueColor)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ScanProgressIndicator_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            ScanProgressIndicator(
                progress: FileScanProgress(
                    totalFiles: 5,
                    completedFiles: 2,
                    currentFile: URL(fileURLWithPath: "/Users/test/Downloads/example.app"),
                    currentPhase: .codeSignatureVerify,
                    overallProgress: 0.45
                )
            )
            
            ScanProgressIndicator(
                progress: FileScanProgress(
                    totalFiles: 1,
                    completedFiles: 0,
                    currentFile: nil,
                    currentPhase: .patternMatching,
                    overallProgress: 0.7
                ),
                compact: true
            )
        }
        .padding()
    }
}
#endif
