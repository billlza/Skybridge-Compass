import SwiftUI
import SkyBridgeCore

/// 行为验证视图 - 滑动拼图验证码
///
/// 用于防止机器人注册，通过分析用户的滑动行为来判断是否为人类
@available(macOS 14.0, *)
public struct BehaviorCaptchaView: View {
    
 // MARK: - 回调
    
 /// 验证完成回调
    public var onVerificationComplete: ((Bool, String?) -> Void)?
    
 /// 取消回调
    public var onCancel: (() -> Void)?
    
 // MARK: - 状态
    
    @State private var puzzleOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var targetPosition: CGFloat = 0
    @State private var isVerifying: Bool = false
    @State private var verificationResult: VerificationState = .pending
    @State private var errorMessage: String?
    
    @StateObject private var trackRecorder = TrackRecorder()
    
 // MARK: - 配置
    
    private let puzzleSize: CGFloat = 50
    private let sliderTrackWidth: CGFloat = 300
    private let sliderTrackHeight: CGFloat = 50
    private let positionTolerance: CGFloat = 5
    
 // MARK: - 枚举
    
    private enum VerificationState {
        case pending
        case success
        case failure
    }
    
 // MARK: - 初始化
    
    public init(
        onVerificationComplete: ((Bool, String?) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.onVerificationComplete = onVerificationComplete
        self.onCancel = onCancel
    }
    
 // MARK: - Body
    
    public var body: some View {
        VStack(spacing: 24) {
 // 标题
            headerView
            
 // 拼图区域
            puzzleAreaView
            
 // 滑动条
            sliderView
            
 // 状态提示
            statusView
            
 // 按钮区域
            buttonArea
        }
        .padding(24)
        .frame(width: 380)
        .background(backgroundGradient)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        .onAppear {
            generateNewPuzzle()
        }
    }
    
 // MARK: - 子视图
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 40))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cyan, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text("安全验证")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
            
            Text("请拖动滑块完成拼图验证")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }
    
    private var puzzleAreaView: some View {
        ZStack {
 // 背景图案
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hue: 0.6, saturation: 0.3, brightness: 0.9),
                            Color(hue: 0.55, saturation: 0.2, brightness: 0.95)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 120)
            
 // 网格图案
            gridPattern
            
 // 目标位置（缺口）
            puzzleHole
                .offset(x: targetPosition - sliderTrackWidth / 2 + puzzleSize / 2)
            
 // 滑块拼图块
            puzzlePiece
                .offset(x: puzzleOffset - sliderTrackWidth / 2 + puzzleSize / 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var gridPattern: some View {
        Canvas { context, size in
            let gridSize: CGFloat = 20
            let lineWidth: CGFloat = 0.5
            
 // 绘制垂直线
            for x in stride(from: 0, through: size.width, by: gridSize) {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: lineWidth)
            }
            
 // 绘制水平线
            for y in stride(from: 0, through: size.height, by: gridSize) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: lineWidth)
            }
        }
        .frame(height: 120)
    }
    
    private var puzzleHole: some View {
        ZStack {
 // 缺口形状
            PuzzlePieceShape()
                .fill(Color.black.opacity(0.3))
                .frame(width: puzzleSize, height: puzzleSize)
            
 // 缺口边框
            PuzzlePieceShape()
                .stroke(Color.white.opacity(0.5), lineWidth: 2)
                .frame(width: puzzleSize, height: puzzleSize)
        }
    }
    
    private var puzzlePiece: some View {
        ZStack {
 // 拼图块
            PuzzlePieceShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hue: 0.55, saturation: 0.4, brightness: 0.85),
                            Color(hue: 0.6, saturation: 0.5, brightness: 0.75)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: puzzleSize, height: puzzleSize)
            
 // 拼图块边框
            PuzzlePieceShape()
                .stroke(Color.white.opacity(0.8), lineWidth: 2)
                .frame(width: puzzleSize, height: puzzleSize)
            
 // 内部图案
            Image(systemName: "puzzlepiece.fill")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.6))
        }
        .shadow(color: .black.opacity(0.3), radius: 5, x: 2, y: 2)
    }
    
    private var sliderView: some View {
        ZStack(alignment: .leading) {
 // 滑动轨道背景
            RoundedRectangle(cornerRadius: sliderTrackHeight / 2)
                .fill(Color.gray.opacity(0.2))
                .frame(width: sliderTrackWidth, height: sliderTrackHeight)
            
 // 已滑动区域
            RoundedRectangle(cornerRadius: sliderTrackHeight / 2)
                .fill(
                    LinearGradient(
                        colors: [.cyan.opacity(0.3), .blue.opacity(0.3)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: puzzleOffset + puzzleSize / 2, height: sliderTrackHeight)
            
 // 滑块
            sliderHandle
                .offset(x: puzzleOffset)
                .gesture(dragGesture)
            
 // 提示文字
            if puzzleOffset < 10 && verificationResult == .pending {
                Text("向右滑动完成验证")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: sliderTrackWidth, height: sliderTrackHeight)
    }
    
    private var sliderHandle: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: handleColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: puzzleSize - 4, height: puzzleSize - 4)
            
            Image(systemName: handleIcon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
        }
        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        .scaleEffect(isDragging ? 1.1 : 1.0)
        .animation(.spring(response: 0.3), value: isDragging)
    }
    
    private var handleColors: [Color] {
        switch verificationResult {
        case .pending:
            return [.cyan, .blue]
        case .success:
            return [.green, .mint]
        case .failure:
            return [.red, .orange]
        }
    }
    
    private var handleIcon: String {
        switch verificationResult {
        case .pending:
            return "arrow.right"
        case .success:
            return "checkmark"
        case .failure:
            return "xmark"
        }
    }
    
    private var statusView: some View {
        Group {
            if isVerifying {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("验证中...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            } else if let error = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                }
            } else if verificationResult == .success {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("验证成功")
                        .font(.system(size: 13))
                        .foregroundColor(.green)
                }
            } else if verificationResult == .failure {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("验证失败，请重试")
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
            }
        }
        .frame(height: 20)
    }
    
    private var buttonArea: some View {
        HStack(spacing: 16) {
 // 刷新按钮
            Button(action: {
                resetPuzzle()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("换一张")
                }
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isVerifying)
            
            Spacer()
            
 // 取消按钮
            Button(action: {
                onCancel?()
            }) {
                Text("取消")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(isVerifying)
        }
    }
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(.windowBackgroundColor),
                Color(.windowBackgroundColor).opacity(0.95)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
 // MARK: - 手势
    
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isVerifying && verificationResult == .pending else { return }
                
                if !isDragging {
                    isDragging = true
                    trackRecorder.startRecording()
                }
                
 // 限制滑动范围
                let newOffset = max(0, min(sliderTrackWidth - puzzleSize, value.translation.width))
                puzzleOffset = newOffset
                
 // 记录轨迹点
                trackRecorder.recordPoint(x: value.location.x, y: value.location.y)
            }
            .onEnded { _ in
                isDragging = false
                verifySlide()
            }
    }
    
 // MARK: - 方法
    
    private func generateNewPuzzle() {
 // 随机生成目标位置（在滑动范围的后半部分）
        let minPosition = sliderTrackWidth * 0.4
        let maxPosition = sliderTrackWidth - puzzleSize - 20
        targetPosition = CGFloat.random(in: minPosition...maxPosition)
    }
    
    private func resetPuzzle() {
        withAnimation(.spring(response: 0.3)) {
            puzzleOffset = 0
            verificationResult = .pending
            errorMessage = nil
        }
        trackRecorder.reset()
        generateNewPuzzle()
    }
    
    private func verifySlide() {
        guard let track = trackRecorder.stopRecording(
            targetX: Double(targetPosition),
            actualX: Double(puzzleOffset)
        ) else {
            verificationResult = .failure
            errorMessage = "轨迹数据异常"
            return
        }
        
        isVerifying = true
        
 // 异步分析
        Task {
 // 1. 检查位置精度
            let positionError = abs(puzzleOffset - targetPosition)
            guard positionError <= positionTolerance else {
                await MainActor.run {
                    isVerifying = false
                    verificationResult = .failure
                    errorMessage = "位置不准确，请重试"
                    
 // 延迟重置
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        resetPuzzle()
                    }
                }
                return
            }
            
 // 2. 行为分析
            let result = await BehaviorAnalyzer.shared.analyzeSlideTrack(track)
            
            await MainActor.run {
                isVerifying = false
                
                if result.isHuman {
                    verificationResult = .success
                    
 // 延迟回调
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        onVerificationComplete?(true, nil)
                    }
                } else {
                    verificationResult = .failure
                    errorMessage = result.reason ?? "行为验证失败"
                    
 // 延迟重置
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        resetPuzzle()
                    }
                    
                    onVerificationComplete?(false, result.reason)
                }
            }
        }
    }
}

// MARK: - 拼图形状

struct PuzzlePieceShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let notchSize = rect.width * 0.25
        let notchOffset = rect.height * 0.35
        
 // 从左上角开始
        path.move(to: CGPoint(x: 0, y: 0))
        
 // 顶边
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        
 // 右边（带凸起）
        path.addLine(to: CGPoint(x: rect.width, y: notchOffset))
        path.addArc(
            center: CGPoint(x: rect.width + notchSize / 2, y: notchOffset + notchSize / 2),
            radius: notchSize / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        
 // 底边
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        
 // 左边
        path.addLine(to: CGPoint(x: 0, y: 0))
        
        return path
    }
}

// MARK: - 预览

#if canImport(PreviewsMacros)
@available(macOS 14.0, *)
#Preview {
    BehaviorCaptchaView { success, error in
        print("验证结果: \(success), 错误: \(error ?? "无")")
    } onCancel: {
        print("取消验证")
    }
    .frame(width: 400, height: 400)
    .background(Color.gray.opacity(0.1))
}
#endif
