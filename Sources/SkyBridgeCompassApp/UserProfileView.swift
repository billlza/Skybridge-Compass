import SwiftUI
import UniformTypeIdentifiers
import SkyBridgeCore

/// 用户信息编辑视图
struct UserProfileView: View {
    @EnvironmentObject var authModel: AuthenticationViewModel
    @Environment(\.dismiss) private var dismiss
    
 // 编辑状态
    @State private var isEditing = false
    @State private var editedDisplayName = ""
    @State private var selectedImageData: Data?
    @State private var showingImagePicker = false
    @State private var isUploading = false
    @State private var uploadError: String?
 // 复制提示显示状态（短暂显示）
    @State private var showCopyToast = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
 // 头像区域
                avatarSection
                
 // 用户信息区域
                userInfoSection
                
                Spacer()
                
 // 操作按钮
                actionButtons
            }
            .padding(24)
            .background(Color(nsColor: .controlBackgroundColor))
            .navigationTitle("用户资料")
 // 顶部轻量提示：复制成功
            .overlay(alignment: .top) {
                if showCopyToast {
                    CopyToastView(text: "已复制星云ID")
                        .transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        SkyBridgeLogger.ui.debugOnly("[UserProfileView] 关闭用户资料窗口")
                        dismiss()
                    }
                }
                
                if isEditing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            saveChanges()
                        }
                        .disabled(isUploading)
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button("编辑") {
                            SkyBridgeLogger.ui.debugOnly("[UserProfileView] 进入编辑模式")
                            isEditing = true
                        }
                    }
                }
            }
        }
        .onAppear {
            setupInitialValues()
        }
        .fileImporter(
            isPresented: $showingImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImageSelection(result)
        }
    }
    
 // MARK: - 头像区域
    private var avatarSection: some View {
        VStack(spacing: 16) {
 // 头像显示
            Button(action: {
                if isEditing {
                    showingImagePicker = true
                }
            }) {
                Group {
                    if let imageData = selectedImageData,
                       let nsImage = NSImage(data: imageData) {
 // 显示选中的新头像
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if let userId = authModel.currentSession?.userIdentifier,
                              let cachedAvatar = AvatarCacheManager.shared.getAvatar(for: userId) {
 // 显示缓存的真实头像
                        Image(nsImage: cachedAvatar)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
 // 显示默认头像 - 显示用户名首字母
                        Circle()
                            .fill(Color.blue.gradient)
                            .overlay(
                                Text(getInitials())
                                    .font(.system(size: 32, weight: .medium))
                                    .foregroundColor(.white)
                            )
                    }
                }
                .frame(width: 100, height: 100)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.2), lineWidth: 2)
                )
                .overlay(
 // 编辑模式下显示相机图标
                    Group {
                        if isEditing {
                            Circle()
                                .fill(Color.black.opacity(0.5))
                                .overlay(
                                    Image(systemName: "camera")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                )
                        }
                    }
                )
            }
            .buttonStyle(.plain)
            .disabled(!isEditing)
            
            if isEditing {
                Text("点击更换头像")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
 // MARK: - 用户信息区域
    private var userInfoSection: some View {
        VStack(spacing: 20) {
 // 星云ID（只读）
            VStack(alignment: .leading, spacing: 8) {
                Text("星云ID")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                HStack {
                    Text(authModel.currentSession?.userIdentifier ?? "未知")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    Spacer()
                    
                    Button(action: copyUserID) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 16))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("复制星云ID")
                }
            }
            
 // 显示名称
            VStack(alignment: .leading, spacing: 8) {
                Text("昵称")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                if isEditing {
                    TextField("请输入昵称", text: $editedDisplayName)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                } else {
                    HStack {
                        Text(authModel.currentSession?.displayName ?? "未设置")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        
                        Spacer()
                    }
                }
            }
            
 // 邮箱（只读）
            VStack(alignment: .leading, spacing: 8) {
                Text("邮箱")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                HStack {
                    Text(authModel.nebulaEmail.isEmpty ? "未绑定" : authModel.nebulaEmail)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 4)
    }
    
 // MARK: - 操作按钮
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if let uploadError {
                Text(uploadError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
            
            if !isEditing {
                Button(action: {
                    isEditing = true
                }) {
                    HStack {
                        Image(systemName: "pencil")
                        Text("编辑信息")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 12) {
                    Button(action: cancelEditing) {
                        Text("取消")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.secondary.opacity(0.2))
                            .foregroundColor(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: saveChanges) {
                        HStack {
                            if isUploading {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text(isUploading ? "保存中..." : "保存")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(isUploading)
                }
            }
        }
    }
    
 // MARK: - 辅助方法
    
 /// 获取用户名首字母
    private func getInitials() -> String {
        guard let displayName = authModel.currentSession?.displayName,
              !displayName.isEmpty else {
            return "用"
        }
        
 // 处理中文和英文名称
        let components = displayName.components(separatedBy: .whitespacesAndNewlines)
        if components.count > 1 {
 // 多个词，取每个词的首字母
            return components.compactMap { $0.first }.map { String($0) }.joined().prefix(2).uppercased()
        } else {
 // 单个词，取前两个字符
            return String(displayName.prefix(2)).uppercased()
        }
    }
    
 /// 设置初始值
    private func setupInitialValues() {
        editedDisplayName = authModel.currentSession?.displayName ?? ""
        
 // 尝试从缓存加载用户头像
        if let userId = authModel.currentSession?.userIdentifier {
            Task { @MainActor in
                if let cachedAvatar = AvatarCacheManager.shared.getAvatar(for: userId) {
 // 将NSImage转换为Data以便在UI中显示
                    if let tiffData = cachedAvatar.tiffRepresentation,
                       let bitmapRep = NSBitmapImageRep(data: tiffData),
                       let jpegData = bitmapRep.representation(using: .jpeg, properties: [:]) {
                        selectedImageData = jpegData
                    }
                }
            }
        }
    }
    
 /// 复制用户ID
    private func copyUserID() {
        if let userID = authModel.currentSession?.userIdentifier {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(userID, forType: .string)
            
 // 显示复制成功的轻量提示，并在 1.5 秒后自动隐藏
            withAnimation(.easeInOut(duration: 0.25)) {
                showCopyToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showCopyToast = false
                }
            }
            SkyBridgeLogger.ui.debugOnly("✅ 已复制星云ID: \(userID)")
        }
    }
    
 /// 处理图片选择
    private func handleImageSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            do {
                let imageData = try Data(contentsOf: url)
 // 验证是否为有效图片
                if NSImage(data: imageData) != nil {
                    selectedImageData = imageData
                } else {
                    uploadError = "选择的文件不是有效的图片格式"
                }
            } catch {
                uploadError = "读取图片文件失败: \(error.localizedDescription)"
            }
            
        case .failure(let error):
            uploadError = "选择图片失败: \(error.localizedDescription)"
        }
    }
    
 /// 取消编辑
    private func cancelEditing() {
        isEditing = false
        setupInitialValues()
        selectedImageData = nil
        uploadError = nil
    }
    
 /// 保存更改
    private func saveChanges() {
        guard !isUploading else { return }
        
        isUploading = true
        uploadError = nil
        
        Task {
            do {
 // 获取当前用户信息
                guard let currentSession = authModel.currentSession else {
                    await MainActor.run {
                        uploadError = "用户会话信息缺失"
                        isUploading = false
                    }
                    return
                }
                
 // 检查是否有需要更新的内容
                let hasDisplayNameChange = !editedDisplayName.isEmpty && editedDisplayName != currentSession.displayName
                let hasAvatarChange = selectedImageData != nil
                
                guard hasDisplayNameChange || hasAvatarChange else {
                    await MainActor.run {
                        uploadError = "没有需要更新的内容"
                        isUploading = false
                    }
                    return
                }
                
 // 调用星云服务更新用户信息
                let updatedUserInfo = try await NebulaService.shared.updateUserProfile(
                    userId: currentSession.userIdentifier,
                    displayName: hasDisplayNameChange ? editedDisplayName : nil,
                    imageData: selectedImageData,
                    accessToken: currentSession.accessToken
                )
                
                await MainActor.run {
 // 更新本地会话信息
                    let updatedSession = AuthSession(
                        accessToken: currentSession.accessToken,
                        refreshToken: currentSession.refreshToken,
                        userIdentifier: currentSession.userIdentifier,
                        displayName: updatedUserInfo.displayName,
                        issuedAt: currentSession.issuedAt
                    )
                    
                    SkyBridgeLogger.ui.debugOnly("🔄 [UserProfileView] 准备更新用户会话信息")
                    SkyBridgeLogger.ui.debugOnly("   原昵称: \(currentSession.displayName)")
                    SkyBridgeLogger.ui.debugOnly("   新昵称: \(updatedUserInfo.displayName)")
                    
 // 如果有头像更新，缓存新头像
                    if hasAvatarChange, let imageData = selectedImageData, let image = NSImage(data: imageData) {
                        AvatarCacheManager.shared.cacheAvatar(image, for: currentSession.userIdentifier)
                        SkyBridgeLogger.ui.debugOnly("   头像已缓存: \(updatedUserInfo.avatar ?? "无")")
                    }
                    
 // 通过AuthenticationService更新会话 - 只设置一次
                    authModel.currentSession = updatedSession
                    do {
                        try AuthenticationService.shared.updateSession(updatedSession)
                    } catch {
                        SkyBridgeLogger.ui.error("❌ [UserProfileView] 会话写入失败: \(error.localizedDescription, privacy: .private)")
                    }
                    SkyBridgeLogger.ui.debugOnly("✅ [UserProfileView] 用户会话已更新")
                    
 // 重置编辑状态
                    isEditing = false
                    selectedImageData = nil
                    isUploading = false
                    
                    SkyBridgeLogger.ui.debugOnly("✅ 用户信息更新成功")
                    SkyBridgeLogger.ui.debugOnly("   新昵称: \(updatedUserInfo.displayName)")
                    if hasAvatarChange {
                        SkyBridgeLogger.ui.debugOnly("   头像已更新: \(updatedUserInfo.avatar ?? "无")")
                    }
                    
 // 关闭编辑界面
                    dismiss()
                }
                
            } catch {
                await MainActor.run {
                    uploadError = "更新失败：\(error.localizedDescription)"
                    isUploading = false
                    
                    SkyBridgeLogger.ui.error("❌ 用户信息更新失败: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }
}

// MARK: - 预览
