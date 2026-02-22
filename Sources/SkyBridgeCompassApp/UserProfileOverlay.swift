import SwiftUI
import UniformTypeIdentifiers
import SkyBridgeCore

/// 现代化用户资料覆盖层组件
/// 采用macOS 26 SwiftUI最佳实践，窗口内展示，无需额外弹窗
@available(macOS 14.0, *)
struct UserProfileOverlay: View {
    @EnvironmentObject var authModel: AuthenticationViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    @Binding var isPresented: Bool

 // 编辑状态
    @State private var isEditing = false
    @State private var editedDisplayName = ""
    @State private var editedPhoneNumber = ""
    @State private var editedEmailAddress = ""
    @State private var selectedImageData: Data?
    @State private var showingImagePicker = false
    @State private var isUploading = false
    @State private var uploadError: String?
    @State private var saveSuccess = false
    @State private var showingSaveResult = false

 // 动画状态
    @State private var overlayOpacity: Double = 0
    @State private var contentScale: Double = 0.8
    @State private var contentOffset: CGFloat = 50

    var body: some View {
        ZStack {
 // 背景遮罩 - 使用macOS 26的新材质效果
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(overlayOpacity * 0.95)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissOverlay()
                }

 // 主要内容区域
            VStack(spacing: 0) {
 // 顶部工具栏
                topToolbar

 // 内容区域
                ScrollView {
                    VStack(spacing: 24) {
 // 头像区域
                        avatarSection

 // 用户信息卡片
                        userInfoCard

 // 操作按钮区域
                        if !isEditing {
                            actionButtons
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }

 // 底部编辑操作栏（仅编辑模式显示）
                if isEditing {
                    editingToolbar
                }
            }
            .frame(width: 420, height: isEditing ? 680 : 620)
            .modifier(GlassStyleModifier(cornerRadius: 20))
            .shadow(color: .black.opacity(0.15), radius: 30, x: 0, y: 15)
            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
            .scaleEffect(contentScale)
            .offset(y: contentOffset)
            .opacity(overlayOpacity)

 // 保存结果提示
            if showingSaveResult {
                saveResultOverlay
            }
        }
        .onAppear {
            setupInitialValues()
            showOverlay()
        }
        .fileImporter(
            isPresented: $showingImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImageSelection(result)
        }
    }

 // MARK: - 顶部工具栏
    private var topToolbar: some View {
        HStack {
 // 标题
            Text(LocalizationManager.shared.localizedString("profile.title"))
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Spacer()

 // 关闭按钮
            Button(action: dismissOverlay) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .background(Color.clear)
            }
            .buttonStyle(.plain)
            .help(LocalizationManager.shared.localizedString("action.close"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
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
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [.blue, .purple]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                Text(getInitials())
                                    .font(.system(size: 36, weight: .medium))
                                    .foregroundColor(.white)
                            )
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(.ultraThinMaterial, lineWidth: 3)
                )
                .overlay(
 // 编辑模式的相机图标
                    Group {
                        if isEditing {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Image(systemName: "camera.fill")
                                        .font(.title2)
                                        .foregroundColor(.primary)
                                )
                        }
                    }
                )
                .scaleEffect(isEditing ? 1.05 : 1.0)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isEditing)
            }
            .buttonStyle(.plain)
            .disabled(!isEditing)

            if isEditing {
                Text("点击更换头像")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .top)))
            }
        }
        .padding(.top, 8)
    }

 // MARK: - 用户信息卡片
    private var userInfoCard: some View {
        VStack(spacing: 20) {
 // 星云ID行
            InfoRow(
                title: "星云ID",
                content: authModel.displayedNebulaId,
                showCopyButton: true,
                copyAction: copyUserID
            )

            Divider()
                .background(.quaternary)

 // 昵称编辑区域
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("昵称")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    if !isEditing {
                        Button("编辑") {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                isEditing = true
                                editedDisplayName = authModel.currentSession?.displayName ?? ""
                                editedPhoneNumber = getPhoneNumber()
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .buttonStyle(.plain)
                    }
                }

                if isEditing {
                    TextField("请输入昵称", text: $editedDisplayName)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .leading)))
                } else {
                    Text(authModel.currentSession?.displayName ?? "未设置")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            Divider()
                .background(.quaternary)

 // 邮箱编辑区域
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("邮箱")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    if !isEditing && (getEmailAddress().isEmpty || getEmailAddress() == "未绑定") {
                        Button("绑定") {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                isEditing = true
                                editedDisplayName = authModel.currentSession?.displayName ?? ""
                                editedPhoneNumber = getPhoneNumber()
                                editedEmailAddress = ""
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .buttonStyle(.plain)
                    } else if !isEditing {
                        Button("编辑") {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                isEditing = true
                                editedDisplayName = authModel.currentSession?.displayName ?? ""
                                editedPhoneNumber = getPhoneNumber()
                                editedEmailAddress = getEmailAddress()
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .buttonStyle(.plain)
                    }
                }

                if isEditing {
                    TextField("请输入邮箱地址", text: $editedEmailAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .leading)))
                } else {
                    HStack {
                    Text(getEmailAddress().isEmpty || getEmailAddress() == "未绑定" ? LocalizationManager.shared.localizedString("profile.email.unbound") : getEmailAddress())
                            .font(.body)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                    if !getEmailAddress().isEmpty && getEmailAddress() != LocalizationManager.shared.localizedString("profile.email.unbound") {
                            Button(action: {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(getEmailAddress(), forType: .string)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 16))
                                    .foregroundColor(.blue)
                                    .frame(width: 32, height: 32)
                                    .background(.quaternary.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .help("复制邮箱")
                        }
                    }
                }
            }

            Divider()
                .background(.quaternary)

 // 手机号编辑区域 - 新增手机号绑定功能
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("手机号")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    if !isEditing && getPhoneNumber().isEmpty {
                        Button("绑定") {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                isEditing = true
                                editedDisplayName = authModel.currentSession?.displayName ?? ""
                                editedPhoneNumber = ""
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .buttonStyle(.plain)
                    }
                }

                if isEditing {
                    TextField("请输入手机号", text: $editedPhoneNumber)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .leading)))
                } else {
                    Text(getPhoneNumber().isEmpty ? LocalizationManager.shared.localizedString("profile.phone.unbound") : getPhoneNumber())
                        .font(.body)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.quaternary, lineWidth: 1)
                )
        )
    }

 // MARK: - 操作按钮
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if let error = uploadError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .top)))
            }

            Button(action: {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    isEditing = true
                    editedDisplayName = authModel.currentSession?.displayName ?? ""
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .medium))
                    Text(LocalizationManager.shared.localizedString("profile.edit"))
                        .font(.system(size: 16, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.blue.gradient)
                )
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
        }
    }

 // MARK: - 编辑工具栏
    private var editingToolbar: some View {
        HStack(spacing: 12) {
            Button(action: cancelEditing) {
                Text(LocalizationManager.shared.localizedString("action.cancel"))
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.quaternary)
                    )
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)

            Button(action: saveChanges) {
                HStack(spacing: 8) {
                    if isUploading {
                        ProgressView()
                            .scaleEffect(0.8)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text(isUploading ? LocalizationManager.shared.localizedString("action.saving") : LocalizationManager.shared.localizedString("action.save"))
                        .font(.system(size: 16, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.blue.gradient)
                )
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(isUploading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .transition(AnyTransition.move(edge: .bottom).combined(with: AnyTransition.opacity))
    }

 // MARK: - 保存结果提示覆盖层
    private var saveResultOverlay: some View {
        VStack(spacing: 16) {
 // 图标
            Image(systemName: saveSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(saveSuccess ? .green : .red)

 // 标题
            Text(saveSuccess ? LocalizationManager.shared.localizedString("profile.save.success") : LocalizationManager.shared.localizedString("profile.save.failure"))
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

 // 详细信息
            if let error = uploadError, !saveSuccess {
                Text(error)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            } else if saveSuccess {
                Text(LocalizationManager.shared.localizedString("profile.save.success.detail"))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

 // 确定按钮
            Button(LocalizationManager.shared.localizedString("action.ok")) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showingSaveResult = false
                    if saveSuccess {
 // 如果保存成功，关闭编辑模式
                        isEditing = false
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        )
        .transition(AnyTransition.scale.combined(with: AnyTransition.opacity))
    }

 // MARK: - 动画方法
    private func showOverlay() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            overlayOpacity = 1.0
            contentScale = 1.0
            contentOffset = 0
        }
    }

    private func dismissOverlay() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            overlayOpacity = 0.0
            contentScale = 0.9
            contentOffset = 30
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isPresented = false
        }
    }

 // MARK: - 辅助方法
    private func getInitials() -> String {
        if let displayName = authModel.currentSession?.displayName, !displayName.isEmpty {
            return String(displayName.prefix(2)).uppercased()
        } else if let userID = authModel.currentSession?.userIdentifier {
            return String(userID.prefix(2)).uppercased()
        } else {
            return "24"
        }
    }

    private func setupInitialValues() {
        editedDisplayName = authModel.currentSession?.displayName ?? ""
        editedPhoneNumber = getPhoneNumber()
        editedEmailAddress = getEmailAddress()
    }

 /// 获取用户邮箱地址 - 修复邮箱显示逻辑
    private func getEmailAddress() -> String {
 // 优先显示当前会话中的邮箱（适用于邮箱注册用户）
        if let session = authModel.currentSession {
 // 如果显示名称是邮箱格式，则显示为邮箱
            if session.displayName.contains("@") {
                return session.displayName
            }
        }

 // 其次显示星云邮箱
        if !authModel.nebulaEmail.isEmpty {
            return authModel.nebulaEmail
        }

 // 最后显示手机邮箱
        if !authModel.phoneEmail.isEmpty {
            return authModel.phoneEmail
        }

        return LocalizationManager.shared.localizedString("profile.email.unbound")
    }

 /// 获取用户手机号
    private func getPhoneNumber() -> String {
 // 这里可以从用户会话或其他地方获取手机号
 // 目前返回空字符串，表示未绑定
        return authModel.phoneNumber.isEmpty ? "" : authModel.phoneNumber
    }

    private func copyUserID() {
        if authModel.currentSession != nil {
            let userID = authModel.displayedNebulaId
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(userID, forType: .string)

 // 可以添加一个临时的成功提示
            withAnimation(.easeInOut(duration: 0.3)) {
 // 这里可以添加复制成功的视觉反馈
            }
        }
    }

    private func handleImageSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // 避免在主线程同步读大文件导致 UI 卡顿
            Task {
                do {
                    let imageData = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: url)
                    }.value
                    if NSImage(data: imageData) != nil {
                        selectedImageData = imageData
                        uploadError = nil
                    } else {
                        selectedImageData = nil
                        uploadError = "无效的图片格式"
                    }
                } catch {
                    selectedImageData = nil
                    uploadError = "读取图片失败: \(error.localizedDescription)"
                }
            }

        case .failure(let error):
            uploadError = "选择图片失败: \(error.localizedDescription)"
        }
    }

    private func cancelEditing() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            isEditing = false
            editedDisplayName = authModel.currentSession?.displayName ?? ""
            editedPhoneNumber = getPhoneNumber()
            editedEmailAddress = getEmailAddress()
            selectedImageData = nil
            uploadError = nil
            saveSuccess = false
            showingSaveResult = false
        }
    }

    private func saveChanges() {
        Task {
            await MainActor.run {
                isUploading = true
                uploadError = nil
            }

            do {
                guard let currentSession = authModel.currentSession else {
                    throw NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "用户未登录"])
                }

                SkyBridgeLogger.ui.debugOnly("🔄 [UserProfileOverlay] 开始保存用户资料更改")
                SkyBridgeLogger.ui.debugOnly("   用户ID: \(currentSession.userIdentifier)")
                SkyBridgeLogger.ui.debugOnly("   原昵称: \(currentSession.displayName)")
                SkyBridgeLogger.ui.debugOnly("   新昵称: \(editedDisplayName)")
                SkyBridgeLogger.ui.debugOnly("   手机号: \(editedPhoneNumber)")
                SkyBridgeLogger.ui.debugOnly("   邮箱: \(editedEmailAddress)")

                let hasDisplayNameChange = editedDisplayName != currentSession.displayName
                let hasPhoneChange = editedPhoneNumber != getPhoneNumber()
                let hasEmailChange = editedEmailAddress != getEmailAddress() && !editedEmailAddress.isEmpty
                let hasAvatarChange = selectedImageData != nil

 // 检查是否使用Supabase模式
                if isSupabaseUser() {
 // 使用Supabase API更新用户资料
                    try await updateSupabaseProfile(
                        displayName: hasDisplayNameChange ? editedDisplayName : nil,
                        phoneNumber: hasPhoneChange ? editedPhoneNumber : nil,
                        email: hasEmailChange ? editedEmailAddress : nil,
                        imageData: hasAvatarChange ? selectedImageData : nil
                    )

 // 如果有邮箱更改，更新本地邮箱信息
                    if hasEmailChange {
                        await MainActor.run {
                            authModel.nebulaEmail = editedEmailAddress
                            SkyBridgeLogger.ui.debugOnly("✅ [UserProfileOverlay] 邮箱已更新: \(editedEmailAddress)")
                        }
                    }
                } else {
 // 使用NebulaService更新用户资料
                    let updatedUserInfo = try await NebulaService.shared.updateUserProfile(
                        userId: currentSession.userIdentifier,
                        displayName: hasDisplayNameChange ? editedDisplayName : nil,
                        imageData: hasAvatarChange ? selectedImageData : nil,
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

                        SkyBridgeLogger.ui.debugOnly("🔄 [UserProfileOverlay] 准备更新用户会话信息")
                        SkyBridgeLogger.ui.debugOnly("   原昵称: \(currentSession.displayName)")
                        SkyBridgeLogger.ui.debugOnly("   新昵称: \(updatedUserInfo.displayName)")

 // 如果有头像更新，缓存新头像
                        if hasAvatarChange, let imageData = selectedImageData, let image = NSImage(data: imageData) {
                            AvatarCacheManager.shared.cacheAvatar(image, for: currentSession.userIdentifier)
                            SkyBridgeLogger.ui.debugOnly("   头像已缓存: \(updatedUserInfo.avatar ?? "无")")
                        }

 // 通过AuthenticationViewModel更新会话，确保UI状态同步
                        authModel.currentSession = updatedSession
                        do {
                            try AuthenticationService.shared.updateSession(updatedSession)
                        } catch {
                            SkyBridgeLogger.ui.error("❌ [UserProfileOverlay] 会话写入失败: \(error.localizedDescription, privacy: .private)")
                        }

 // 如果有邮箱更改，更新本地邮箱信息
                        if hasEmailChange {
                            authModel.nebulaEmail = editedEmailAddress
                            SkyBridgeLogger.ui.debugOnly("✅ [UserProfileOverlay] 邮箱已更新: \(editedEmailAddress)")
                        }

 // 如果有手机号更改，更新本地手机号信息
                        if hasPhoneChange {
                            authModel.phoneNumber = editedPhoneNumber
                            SkyBridgeLogger.ui.debugOnly("✅ [UserProfileOverlay] 手机号已更新: \(editedPhoneNumber)")
                        }

                        SkyBridgeLogger.ui.debugOnly("✅ [UserProfileOverlay] 用户会话已更新")

 // 重置编辑状态
                        isEditing = false
                        selectedImageData = nil
                        isUploading = false

                        SkyBridgeLogger.ui.debugOnly("✅ [UserProfileOverlay] 用户资料保存成功")

 // 显示保存成功提示
                        saveSuccess = true
                        uploadError = nil
                        isUploading = false

                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            showingSaveResult = true
                        }
                    }
                }
            } catch {
                SkyBridgeLogger.ui.error("❌ [UserProfileOverlay] 保存用户资料失败: \(error.localizedDescription, privacy: .private)")
                await MainActor.run {
 // 更精确地检查是否为认证错误
                let errorString = error.localizedDescription
                var isAuthError = false
                var supabaseAuthMessage: String?
                let supabaseMessage = SupabaseService.userMessage(for: error)

 // 检查是否为SkyBridgeCore中定义的认证相关错误
                if let supabaseError = error as? SupabaseService.SupabaseError {
                    switch supabaseError {
                    case .authenticationFailed(let message):
                        supabaseAuthMessage = message
                    default:
                        break
                    }
                } else if let nebulaError = error as? NebulaService.NebulaError {
                    switch nebulaError {
                    case .authenticationFailed:
                        isAuthError = true
                    default:
                        isAuthError = false
                    }
                }

                if let supabaseMessage {
                    SkyBridgeLogger.ui.debugOnly("ℹ️ [UserProfileOverlay] Supabase错误提示: \(supabaseMessage)")
                    saveSuccess = false
                    uploadError = "保存失败：\(supabaseMessage)"
                } else {
 // 只有在明确收到401 Unauthorized或403 Forbidden且错误消息明确指示认证问题时才认为是认证错误
                    if !isAuthError {
                        isAuthError = (errorString.contains("401") || errorString.contains("403")) &&
                            (errorString.contains("Unauthorized") || errorString.contains("Forbidden") ||
                             errorString.contains("token") || errorString.contains("认证"))
                    }

                    if isAuthError {
                        SkyBridgeLogger.ui.debugOnly("ℹ️ [UserProfileOverlay] 认证失败，保持登录状态并提示重试")
                        saveSuccess = false
                        uploadError = "保存失败：会话过期，请重新登录"
                    } else {
 // 对于非认证错误，显示具体错误信息但不强制退出登录
                        SkyBridgeLogger.ui.debugOnly("ℹ️ [UserProfileOverlay] 非认证错误，保持登录状态")
                        saveSuccess = false
                        if let supabaseAuthMessage = supabaseAuthMessage {
                            uploadError = "保存失败：认证失败：\(supabaseAuthMessage)"
                        } else {
                            uploadError = "保存失败：\(error.localizedDescription)"
                        }
                    }
                }

                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showingSaveResult = true
                    }

                    isUploading = false
                }
            }
        }
    }

 /// 检查是否为Supabase用户
    private func isSupabaseUser() -> Bool {
        guard let session = authModel.currentSession else { return false }
        guard SupabaseConfiguration.shared.isConfigured else { return false }
        guard session.accessToken != "pending_verification" else { return false }
        return SupabaseService.shared.isSupabaseAccessToken(session.accessToken)
    }

 /// 使用Supabase API更新用户资料
    private func updateSupabaseProfile(displayName: String?, phoneNumber: String?, email: String?, imageData: Data?) async throws {
        guard var session = authModel.currentSession else {
            throw NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "用户未登录"])
        }

        SkyBridgeLogger.ui.debugOnly("🔄 [UserProfileOverlay] 使用Supabase更新用户资料")

 // 尝试刷新 Token 以确保有效性
        if let refreshToken = session.refreshToken {
            do {
                SkyBridgeLogger.ui.debugOnly("🔄 [UserProfileOverlay] 尝试刷新访问令牌")
                let newSession = try await SupabaseService.shared.refreshAccessToken(refreshToken)
                session = newSession
                await MainActor.run {
                    authModel.currentSession = newSession
                    do {
                        try AuthenticationService.shared.updateSession(newSession)
                    } catch {
                        SkyBridgeLogger.ui.error("❌ [UserProfileOverlay] 刷新会话写入失败: \(error.localizedDescription, privacy: .private)")
                    }
                }
                SkyBridgeLogger.ui.debugOnly("✅ [UserProfileOverlay] 访问令牌刷新成功")
            } catch {
                SkyBridgeLogger.ui.debugOnly("⚠️ [UserProfileOverlay] 令牌刷新失败，使用现有令牌: \(error.localizedDescription)")
            }
        }

 // 如果有头像更新，先上传头像到Supabase Storage
        if let imageData = imageData {
            do {
                SkyBridgeLogger.ui.debugOnly("📸 [UserProfileOverlay] 开始上传头像到Supabase Storage")
                let avatarUrl = try await SupabaseService.shared.uploadAvatarToStorage(
                    userId: session.userIdentifier,
                    imageData: imageData,
                    accessToken: session.accessToken
                )

                SkyBridgeLogger.ui.debugOnly("✅ [UserProfileOverlay] 头像上传成功: \(avatarUrl)")

 // 本地缓存头像
                if let image = NSImage(data: imageData) {
                    AvatarCacheManager.shared.cacheAvatar(image, for: session.userIdentifier)
                    SkyBridgeLogger.ui.debugOnly("✅ [UserProfileOverlay] 头像已缓存到本地")
                }
            } catch {
                SkyBridgeLogger.ui.error("❌ [UserProfileOverlay] 头像上传失败: \(error.localizedDescription, privacy: .private)")
                throw error
            }
        }

 // 调用真实的Supabase API更新用户资料（必要时刷新令牌并重试）
        var success = false
        let emailToUpdate = email
        do {
            success = try await SupabaseService.shared.updateUserProfile(
                displayName: displayName,
                phoneNumber: phoneNumber,
                email: emailToUpdate,
                accessToken: session.accessToken
            )
        } catch {
            let isForbidden = (error as? SupabaseService.SupabaseError).flatMap { supabaseError in
                switch supabaseError {
                case .httpStatus(let code, _):
                    return code == 403
                case .authenticationFailed(let message):
                    return message.contains("403")
                default:
                    return false
                }
            } ?? false

            if isForbidden && emailToUpdate == nil {
                SkyBridgeLogger.ui.debugOnly("⚠️ [UserProfileOverlay] auth API 403，改用 profiles 表更新")
                success = try await SupabaseService.shared.updateProfilesTable(
                    userId: session.userIdentifier,
                    displayName: displayName,
                    phoneNumber: phoneNumber,
                    accessToken: session.accessToken
                )
            } else if let refreshToken = session.refreshToken {
                SkyBridgeLogger.ui.debugOnly("🔄 [UserProfileOverlay] auth API 失败，尝试刷新令牌并重试")
                let newSession = try await SupabaseService.shared.refreshAccessToken(refreshToken)
                session = newSession
                await MainActor.run {
                    authModel.currentSession = newSession
                    do {
                        try AuthenticationService.shared.updateSession(newSession)
                    } catch {
                        SkyBridgeLogger.ui.error("❌ [UserProfileOverlay] 刷新会话写入失败: \(error.localizedDescription, privacy: .private)")
                    }
                }
                do {
                    success = try await SupabaseService.shared.updateUserProfile(
                        displayName: displayName,
                        phoneNumber: phoneNumber,
                        email: emailToUpdate,
                        accessToken: newSession.accessToken
                    )
                } catch {
                    let retryForbidden = (error as? SupabaseService.SupabaseError).flatMap { supabaseError in
                        switch supabaseError {
                        case .httpStatus(let code, _):
                            return code == 403
                        case .authenticationFailed(let message):
                            return message.contains("403")
                        default:
                            return false
                        }
                    } ?? false

                    if retryForbidden && emailToUpdate == nil {
                        SkyBridgeLogger.ui.debugOnly("⚠️ [UserProfileOverlay] 重试仍为 403，改用 profiles 表更新")
                        success = try await SupabaseService.shared.updateProfilesTable(
                            userId: session.userIdentifier,
                            displayName: displayName,
                            phoneNumber: phoneNumber,
                            accessToken: newSession.accessToken
                        )
                    } else {
                        throw error
                    }
                }
            } else {
                SkyBridgeLogger.ui.debugOnly("⚠️ [UserProfileOverlay] 无刷新令牌，尝试 profiles 表")
                success = try await SupabaseService.shared.updateProfilesTable(
                    userId: session.userIdentifier,
                    displayName: displayName,
                    phoneNumber: phoneNumber,
                    accessToken: session.accessToken
                )
            }
        }

        if success {
            await MainActor.run {
 // 更新本地会话信息
                let updatedSession = AuthSession(
                    accessToken: session.accessToken,
                    refreshToken: session.refreshToken,
                    userIdentifier: session.userIdentifier,
                    displayName: displayName ?? session.displayName,
                    issuedAt: session.issuedAt
                )

                authModel.currentSession = updatedSession
                do {
                    try AuthenticationService.shared.updateSession(updatedSession)
                } catch {
                    SkyBridgeLogger.ui.error("❌ [UserProfileOverlay] 会话写入失败: \(error.localizedDescription, privacy: .private)")
                }

 // 如果有手机号更新，保存到AuthenticationViewModel
                if let phoneNumber = phoneNumber {
                    authModel.phoneNumber = phoneNumber
                    SkyBridgeLogger.ui.debugOnly("✅ [UserProfileOverlay] 手机号已更新: \(phoneNumber)")
                }

 // 如果有邮箱更新，保存到AuthenticationViewModel
                if let email = email {
                    authModel.nebulaEmail = email
                    SkyBridgeLogger.ui.debugOnly("✅ [UserProfileOverlay] 邮箱已更新: \(email)")
                }

 // 重置编辑状态
                isEditing = false
                selectedImageData = nil
                isUploading = false

                SkyBridgeLogger.ui.debugOnly("✅ [UserProfileOverlay] Supabase用户资料更新成功")

 // 显示保存成功提示
                saveSuccess = true
                uploadError = nil

                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showingSaveResult = true
                }
            }
        } else {
            throw NSError(domain: "SupabaseError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Supabase用户资料更新失败"])
        }
    }
}

//

// MARK: - 信息行组件
struct InfoRow: View {
    let title: String
    let content: String
    let showCopyButton: Bool
    let copyAction: (() -> Void)?

    init(title: String, content: String, showCopyButton: Bool = false, copyAction: (() -> Void)? = nil) {
        self.title = title
        self.content = content
        self.showCopyButton = showCopyButton
        self.copyAction = copyAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            HStack {
                Text(content)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if showCopyButton {
                    Button(action: {
                        copyAction?()
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 16))
                            .foregroundColor(.blue)
                            .frame(width: 32, height: 32)
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("复制\(title)")
                }
            }
        }
    }
}
