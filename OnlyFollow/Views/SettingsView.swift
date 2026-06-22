import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var bilibiliCookie = AppSettings.bilibiliCookie
    @State private var showCookieHelp = false
    @State private var showQRLogin = false
    @State private var loginState: BilibiliLoginState = .unknown
    @State private var showAdvanced = false
    /// 抖音登录态（仅 cookie 维度：有 sessionid 就算已登录）
    @State private var douyinHasSession: Bool = AppSettings.hasDouyinCookie
    @State private var showDouyinLogin = false
    /// 同步状态(订阅变更;按钮按下后会自动更新)
    @ObservedObject private var syncCoordinator = SyncCoordinator.shared
    /// Embedder 状态(进度/运行中/上次结果)
    @ObservedObject private var embedderState = EmbedderState.shared
    /// 合集补全状态
    @ObservedObject private var seasonBackfillState = SeasonBackfillState.shared
    @State private var seasonAutoBackfillEnabled: Bool = AppSettings.seasonAutoBackfillEnabled
    /// 同步配置输入框(本地 state,保存时才写 UserDefaults)
    @State private var syncTokenInput: String = ""
    @State private var syncRepoInput: String = ""
    /// 状态:输入框是否被改过
    @State private var syncTokenDirty: Bool = false
    @State private var syncRepoDirty: Bool = false
    /// "修改 Token" 按钮的展开状态
    @State private var syncTokenEditing: Bool = false
    /// AI 推荐配置输入框(本地 state, 保存时写 UserDefaults)
    @State private var seasonAutoplayEnabled: Bool = AppSettings.seasonAutoplayEnabled
    @State private var aiRecommendEnabled: Bool = AppSettings.aiRecommendEnabled
    @State private var localRecommendMode: AppSettings.LocalRecommendMode = AppSettings.localRecommendMode
    @State private var recommendCount: Int = AppSettings.recommendCount
    /// Embedding
    @State private var embeddingBaseURL: String = AppSettings.embeddingBaseURL
    @State private var embeddingAPIKey: String = AppSettings.embeddingAPIKey
    @State private var embeddingAPIKeyEditing: Bool = false
    @State private var embeddingDirty: Bool = false
    @State private var embeddingModel: String = AppSettings.embeddingModel
    /// DeepSeek
    @State private var deepseekBaseURL: String = AppSettings.deepseekBaseURL
    @State private var deepseekAPIKey: String = AppSettings.deepseekAPIKey
    @State private var deepseekAPIKeyEditing: Bool = false
    @State private var deepseekDirty: Bool = false
    @State private var deepseekModel: String = AppSettings.deepseekModel
    /// 测试连接中
    @State private var syncTesting: Bool = false
    /// 测试结果(展示在 footer 下方)
    @State private var syncTestResult: String? = nil

    var body: some View {
        Form {
            loginSection
            douyinLoginSection
            recommendSection
            seasonBackfillSection
            embeddingSection
            deepseekSection
            syncSection
            advancedToggleSection
            if showAdvanced {
                advancedSection
            }
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showQRLogin) {
            LoginView(isPresented: $showQRLogin)
        }
        .sheet(isPresented: $showDouyinLogin) {
            DouyinLoginView(isPresented: $showDouyinLogin)
        }
        .task {
            loginState = await BilibiliSessionManager.shared.verifyLogin()
            douyinHasSession = AppSettings.hasDouyinCookie
            // 预填现有配置
            syncTokenInput = SyncStorage.shared.githubToken ?? ""
            syncRepoInput = SyncStorage.shared.repoPath ?? ""
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: DouyinSessionManager.loginSucceededNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            douyinHasSession = AppSettings.hasDouyinCookie
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: BilibiliSessionManager.loginStateDidChangeNotification)
                .receive(on: RunLoop.main)
        ) { note in
            if let state = note.object as? BilibiliLoginState {
                loginState = state
                bilibiliCookie = AppSettings.bilibiliCookie
            }
        }
    }

    // MARK: - 登录态

    private var loginSection: some View {
        Section {
            HStack {
                Image(systemName: loginIconName)
                    .font(.title2)
                    .foregroundStyle(loginIconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loginTitle).font(.subheadline.bold())
                    Text(loginSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .loggedIn = loginState {
                    Button("退出登录") {
                        BilibiliSessionManager.shared.logout()
                        loginState = .loggedOut
                    }
                    .foregroundStyle(.red)
                    .font(.caption)
                }
            }

            Button {
                showQRLogin = true
            } label: {
                Label("扫码登录 B站", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
        } header: {
            Text("B站登录")
        } footer: {
            Text(loginFooter)
        }
    }


    // MARK: - 抖音登录

    private var douyinLoginSection: some View {
        Section {
            HStack {
                Image(systemName: douyinHasSession ? "person.crop.circle.fill" : "person.crop.circle.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(douyinHasSession ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(douyinHasSession ? "已登录抖音" : "未登录抖音")
                        .font(.subheadline.bold())
                    Text(douyinHasSession ? "扫码登录后的 sessionid 已保存" : "登录后可以查看博主的最新视频和直播状态")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if douyinHasSession {
                    Button("退出登录") {
                        AppSettings.douyinCookie = ""
                        douyinHasSession = false
                    }
                    .foregroundStyle(.red)
                    .font(.caption)
                }
            }

            Button {
                showDouyinLogin = true
            } label: {
                Label("扫码登录抖音", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
        } header: {
            Text("抖音登录")
        } footer: {
            Text("抖音网页端的 QR 登录需要 JS,本 App 用 WKWebView 加载 sso.douyin.com 展示二维码,扫码后自动保存 sessionid 到本地。")
                .font(.caption2)
        }
    }

    // MARK: - 播下一个 推荐

    private var recommendSection: some View {
        Section {
            Toggle(isOn: $seasonAutoplayEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("合集自动连播").font(.subheadline)
                    Text("视频在 B 站合集里时, 播完自动切到下一个").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: seasonAutoplayEnabled) { _, new in
                AppSettings.seasonAutoplayEnabled = new
            }

            Toggle(isOn: $aiRecommendEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 智能推荐").font(.subheadline)
                    Text("无合集时, 播完弹「推荐视频」页(需 embedding / DeepSeek key)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: aiRecommendEnabled) { _, new in
                AppSettings.aiRecommendEnabled = new
            }

            Picker("推荐模式", selection: $localRecommendMode) {
                Text("本地向量 (默认)").tag(AppSettings.LocalRecommendMode.vector)
                Text("DeepSeek LLM").tag(AppSettings.LocalRecommendMode.deepseek)
            }
            .pickerStyle(.menu)
            .onChange(of: localRecommendMode) { _, new in
                AppSettings.localRecommendMode = new
            }

            Stepper(value: $recommendCount, in: 6...12) {
                HStack {
                    Text("推荐数量")
                    Spacer()
                    Text("\(recommendCount)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .onChange(of: recommendCount) { _, new in
                AppSettings.recommendCount = new
            }
        } header: {
            Text("「播完下一个」")
        } footer: {
            Text("路径 1：B 站 UGC 合集(零成本, 自动连播)\n路径 2：本地向量库或 DeepSeek(播完后弹窗, 主动选)")
                .font(.caption2)
        }
    }

    // MARK: - 合集补全

    private var seasonBackfillSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("本地已识别合集").font(.subheadline)
                    Spacer()
                    Text("\(seasonBackfillState.knownSeasonCount) 个")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("系统知道的合集数(去重)。需要先点开过合集视频系统才能识别")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Toggle(isOn: $seasonAutoBackfillEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动补全合集").font(.subheadline)
                    Text("播放合集视频时, 后台拉该合集最近 30 个, 自动入库").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: seasonAutoBackfillEnabled) { _, new in
                AppSettings.seasonAutoBackfillEnabled = new
            }
            HStack {
                Button {
                    seasonBackfillState.startBackfillAll(context: modelContext)
                } label: {
                    if seasonBackfillState.isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("补全中 \(seasonBackfillState.processed)/\(seasonBackfillState.total)")
                                .font(.caption)
                        }
                    } else {
                        Label("补全所有已知合集", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(seasonBackfillState.isRunning || seasonBackfillState.knownSeasonCount == 0)
                if seasonBackfillState.knownSeasonCount == 0 {
                    Text("先去点开合集视频").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let lastRun = seasonBackfillState.lastRunAt, !seasonBackfillState.isRunning {
                Text("上次补全: \(formatTimeAgo(lastRun))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("合集")
        } footer: {
            Text("• 自动补全: 播放合集视频时, 后台拉 30 个(覆盖 UP 主最近加的合集视频), 用户无感\n• 手动补全: 对每个已知合集拉 30 个, 1.5s 限流避免反爬\n• 单合集完整版: 进合集 sheet 顶部点「补全本合集所有视频」, 分页拉完")
                .font(.caption2)
        }
    }

    // MARK: - Embedding 配置

    private var embeddingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Base URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://dashscope.aliyuncs.com/compatible-mode/v1", text: $embeddingBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: embeddingBaseURL) { _, _ in embeddingDirty = true }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key").font(.caption).foregroundStyle(.secondary)
                if !AppSettings.hasEmbeddingAPIKey || embeddingAPIKeyEditing {
                    SecureField("sk-...", text: $embeddingAPIKey)
                        .font(.system(.caption, design: .monospaced))
                        .onChange(of: embeddingAPIKey) { _, _ in embeddingDirty = true }
                } else {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(maskedKey(AppSettings.embeddingAPIKey))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("修改") { embeddingAPIKeyEditing = true }
                            .font(.caption2)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("模型名").font(.caption).foregroundStyle(.secondary)
                TextField("text-embedding-v4", text: $embeddingModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: embeddingModel) { _, _ in embeddingDirty = true }
            }
            if embeddingDirty {
                HStack {
                    Button("保存") {
                        AppSettings.embeddingBaseURL = embeddingBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        let key = embeddingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        AppSettings.embeddingAPIKey = key
                        AppSettings.embeddingModel = embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        embeddingDirty = false
                        embeddingAPIKeyEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(embeddingBaseURL.isEmpty)
                    Button("放弃修改") {
                        embeddingBaseURL = AppSettings.embeddingBaseURL
                        embeddingAPIKey = AppSettings.embeddingAPIKey
                        embeddingModel = AppSettings.embeddingModel
                        embeddingDirty = false
                        embeddingAPIKeyEditing = false
                    }
                    .foregroundStyle(.secondary)
                }
            }
            // 进度展示 + 重建按钮
            embedderProgressRow
        } header: {
            Text("Embedding（本地向量库）")
        } footer: {
            Text("默认指向阿里云百炼 compatible-mode(OpenAI 协议)。其他兼容服务也可填。\nApp 启动时后台增量建库; 推荐在本地跑(1k 标题约 0.05 元)")
                .font(.caption2)
        }
    }

    /// Embedding 建库进度展示 + 重建按钮
    @ViewBuilder
    private var embedderProgressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("本地向量库").font(.subheadline)
                Spacer()
                if embedderState.isRunning {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("构建中").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(embedderState.embeddedCount) / \(embedderState.embeddedCount + embedderState.pendingCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if embedderState.isRunning && embedderState.total > 0 {
                ProgressView(value: Double(embedderState.processed), total: Double(embedderState.total))
            }
            if let lastRun = embedderState.lastRunAt, !embedderState.isRunning {
                Text("上次构建: \(formatTimeAgo(lastRun)) · 写入 \(embedderState.lastRunCount) 条")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let err = embedderState.lastError {
                Text("⚠️ \(err)").font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                Button {
                    embedderState.startRebuild()
                } label: {
                    Label(embedderState.isRunning ? "构建中..." : "重新构建向量库",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(embedderState.isRunning || !AppSettings.hasEmbeddingAPIKey)
                if !AppSettings.hasEmbeddingAPIKey {
                    Text("未配 API key").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            // 进入页面时刷一次当前条目数 + 已知合集数
            embedderState.refreshCounts(context: modelContext)
            seasonBackfillState.refreshKnownCount(context: modelContext)
        }
    }

    private func formatTimeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        return "\(Int(interval / 86400)) 天前"
    }

    // MARK: - DeepSeek 配置

    private var deepseekSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Base URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://api.deepseek.com/v1", text: $deepseekBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: deepseekBaseURL) { _, _ in deepseekDirty = true }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key").font(.caption).foregroundStyle(.secondary)
                if !AppSettings.hasDeepSeekAPIKey || deepseekAPIKeyEditing {
                    SecureField("sk-...", text: $deepseekAPIKey)
                        .font(.system(.caption, design: .monospaced))
                        .onChange(of: deepseekAPIKey) { _, _ in deepseekDirty = true }
                } else {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(maskedKey(AppSettings.deepseekAPIKey))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("修改") { deepseekAPIKeyEditing = true }
                            .font(.caption2)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("模型").font(.caption).foregroundStyle(.secondary)
                TextField("deepseek-v4-flash", text: $deepseekModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: deepseekModel) { _, _ in deepseekDirty = true }
            }
            if deepseekDirty {
                HStack {
                    Button("保存") {
                        AppSettings.deepseekBaseURL = deepseekBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        let key = deepseekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        AppSettings.deepseekAPIKey = key
                        AppSettings.deepseekModel = deepseekModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        deepseekDirty = false
                        deepseekAPIKeyEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(deepseekBaseURL.isEmpty)
                    Button("放弃修改") {
                        deepseekBaseURL = AppSettings.deepseekBaseURL
                        deepseekAPIKey = AppSettings.deepseekAPIKey
                        deepseekModel = AppSettings.deepseekModel
                        deepseekDirty = false
                        deepseekAPIKeyEditing = false
                    }
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("DeepSeek（LLM 推荐备选）")
        } footer: {
            Text("默认 deepseek-v4-flash(便宜快), 想要更准可改 deepseek-v4-pro。\n不在默认连播链路里：点播放器右上「AI 智能推荐」按钮才会用, 不打扰主流程")
                .font(.caption2)
        }
    }

    private func maskedKey(_ key: String) -> String {
        if key.isEmpty { return "" }
        if key.count <= 8 { return String(repeating: "•", count: key.count) }
        return key.prefix(4) + String(repeating: "•", count: max(4, key.count - 8)) + key.suffix(4)
    }
    // MARK: - GitHub 同步设置

    private var syncSection: some View {
        Section {
            // 状态行
            HStack {
                Image(systemName: syncIconName)
                    .font(.title2)
                    .foregroundStyle(syncIconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(syncTitle).font(.subheadline.bold())
                    Text(syncSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if syncCoordinator.status.isWorking || syncTesting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            // Repo 输入
            VStack(alignment: .leading, spacing: 4) {
                Text("仓库路径").font(.caption).foregroundStyle(.secondary)
                TextField("username/repo", text: $syncRepoInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: syncRepoInput) { _, _ in syncRepoDirty = true }
            }

            // Token 输入
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Personal Access Token").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if SyncStorage.shared.githubToken != nil {
                        Button(syncTokenEditing ? "取消" : "修改") {
                            syncTokenEditing.toggle()
                        }
                        .font(.caption2)
                    }
                }
                if SyncStorage.shared.githubToken == nil || syncTokenEditing {
                    SecureField("ghp_...", text: $syncTokenInput)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: syncTokenInput) { _, _ in syncTokenDirty = true }
                } else {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(maskedToken(SyncStorage.shared.githubToken ?? ""))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 保存 / 取消
            if syncTokenDirty || syncRepoDirty {
                HStack {
                    Button("保存配置") {
                        saveSyncConfig()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(syncRepoInput.isEmpty || syncTokenInput.isEmpty)
                    Button("放弃修改") {
                        syncTokenInput = SyncStorage.shared.githubToken ?? ""
                        syncRepoInput = SyncStorage.shared.repoPath ?? ""
                        syncTokenDirty = false
                        syncRepoDirty = false
                        syncTokenEditing = false
                    }
                    .foregroundStyle(.secondary)
                }
            }

            // 操作按钮
            HStack {
                Button {
                    Task { await syncCoordinator.pullNow() }
                } label: {
                    Label("立即拉取", systemImage: "arrow.down.circle")
                }
                .disabled(!isSyncConfigured || syncCoordinator.status.isWorking)

                Button {
                    Task { await syncCoordinator.kickUpload() }
                } label: {
                    Label("立即推送", systemImage: "arrow.up.circle")
                }
                .disabled(!isSyncConfigured || syncCoordinator.status.isWorking)

                Spacer()

                Button {
                    Task { await testConnection() }
                } label: {
                    Label("测试", systemImage: "wifi.circle")
                }
                .disabled(syncRepoInput.isEmpty || syncTokenInput.isEmpty || syncTesting)
            }
            .font(.caption)

            if let result = syncTestResult {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("数据同步 (GitHub)")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(syncFooter)
                if let path = SyncStorage.shared.repoPath {
                    Link("在 GitHub 上查看 commit 历史",
                         destination: URL(string: "https://github.com/\(path)/commits/main")!)
                        .font(.caption2)
                }
            }
        }
    }

    private var isSyncConfigured: Bool {
        guard let path = SyncStorage.shared.repoPath, !path.isEmpty,
              let token = SyncStorage.shared.githubToken, !token.isEmpty
        else { return false }
        return true
    }

    private func saveSyncConfig() {
        let trimmedToken = syncTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRepo = syncRepoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        SyncStorage.shared.githubToken = trimmedToken.isEmpty ? nil : trimmedToken
        SyncStorage.shared.repoPath = trimmedRepo.isEmpty ? nil : trimmedRepo
        // 重新配置了 sync 后端:之前"已确认过状态"的前提不再成立,必须重新拉一次
        // 防止"换 repo/token 后立刻把本地(可能是空的)数据推上去覆盖远端"
        SyncStorage.shared.resetHasCompletedInitialPull()
        syncTokenDirty = false
        syncRepoDirty = false
        syncTokenEditing = false
        // 立即触发一次拉取验证
        Task { await syncCoordinator.pullNow() }
    }

    private func testConnection() async {
        // 先保存到内存,再测(测完不一定要保留)
        let savedToken = SyncStorage.shared.githubToken
        let savedRepo = SyncStorage.shared.repoPath
        SyncStorage.shared.githubToken = syncTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        SyncStorage.shared.repoPath = syncRepoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        syncTesting = true
        syncTestResult = nil
        defer {
            syncTesting = false
            // 测完还原(避免脏数据残留)
            SyncStorage.shared.githubToken = savedToken
            SyncStorage.shared.repoPath = savedRepo
        }
        do {
            let snapshot = try await SyncStorage.shared.readSnapshot()
            if snapshot == nil {
                syncTestResult = "✓ 连接成功(云端无快照,首次拉取会跳过)"
            } else {
                syncTestResult = "✓ 连接成功,云端快照含 \(snapshot!.creators.count) 个关注 / \(snapshot!.videos.count) 个视频"
            }
        } catch SyncStorageError.unauthorized {
            syncTestResult = "✗ Token 无效(401),请重新生成"
        } catch SyncStorageError.notConfigured {
            syncTestResult = "✗ 配置不完整"
        } catch {
            syncTestResult = "✗ \(error.localizedDescription)"
        }
    }

    private func maskedToken(_ token: String) -> String {
        if token.isEmpty { return "" }
        if token.count <= 8 { return String(repeating: "•", count: token.count) }
        let prefix = token.prefix(4)
        let suffix = token.suffix(4)
        let middle = String(repeating: "•", count: max(4, token.count - 8))
        return "\(prefix)\(middle)\(suffix)"
    }

    // MARK: - 高级(手动 Cookie)

    private var advancedToggleSection: some View {
        Section {
            Button {
                withAnimation { showAdvanced.toggle() }
            } label: {
                HStack {
                    Label("高级:手动粘贴 Cookie", systemImage: "chevron.right.square")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - 子视图

    private var loginIconName: String {
        switch loginState {
        case .loggedIn: return "person.crop.circle.fill.badge.checkmark"
        case .loggedOut: return "person.crop.circle.badge.exclamationmark"
        case .unknown: return "person.crop.circle"
        }
    }

    private var loginIconColor: Color {
        switch loginState {
        case .loggedIn: return .green
        case .loggedOut: return .orange
        case .unknown: return .secondary
        }
    }

    private var loginTitle: String {
        switch loginState {
        case .loggedIn(_, let name): return name.isEmpty ? "已登录" : name
        case .loggedOut: return "未登录"
        case .unknown: return "验证中…"
        }
    }

    private var loginSubtitle: String {
        switch loginState {
        case .loggedIn(_, let name):
            if !name.isEmpty, AppSettings.bilibiliLoggedUID != 0 {
                return "UID: \(AppSettings.bilibiliLoggedUID) · 已保存登录态"
            }
            return "已保存登录态"
        case .loggedOut:
            return AppSettings.hasBilibiliCookie
                ? "Cookie 存在但验证未通过,可能已失效"
                : "未登录时请求易被限流"
        case .unknown:
            return ""
        }
    }

    private var loginFooter: String {
        switch loginState {
        case .loggedIn: return "登录态会持久保存,失效时自动提示重新登录"
        case .loggedOut: return "扫码登录后即可正常浏览所有内容;如扫码不便可展开高级选项手动粘贴 Cookie"
        case .unknown: return "正在验证登录态…"
        }
    }

    // MARK: - 同步 UI 子组件

    private var syncIconName: String {
        switch syncCoordinator.status {
        case .unavailable: return "icloud.slash"
        case .error: return "exclamationmark.icloud"
        case .exporting, .uploading, .downloading, .merging: return "arrow.triangle.2.circlepath"
        case .success, .idle: return "checkmark.icloud"
        }
    }

    private var syncIconColor: Color {
        switch syncCoordinator.status {
        case .unavailable: return .gray
        case .error: return .orange
        case .exporting, .uploading, .downloading, .merging: return .blue
        case .success: return .green
        case .idle: return .secondary
        }
    }

    private var syncTitle: String {
        switch syncCoordinator.status {
        case .idle: return isSyncConfigured ? "等待同步" : "未配置"
        case .unavailable: return "未配置同步"
        case .exporting: return "正在准备…"
        case .uploading: return "正在推送到 GitHub…"
        case .downloading: return "正在从 GitHub 下载…"
        case .merging: return "正在合并数据…"
        case .success: return "已同步"
        case .error: return "同步出错"
        }
    }

    private var syncSubtitle: String {
        switch syncCoordinator.status {
        case .idle:
            if let last = syncCoordinator.lastSyncedAt {
                return "上次同步: \(timeAgoString(from: last))"
            }
            return isSyncConfigured ? "改动后约 5 秒自动同步" : "填好 Token + 仓库路径后启用"
        case .unavailable(let reason):
            return reason
        case .error(let msg):
            return msg
        case .success:
            if let last = syncCoordinator.lastSyncedAt {
                return "上次同步: \(timeAgoString(from: last))"
            }
            return "已同步"
        case .exporting, .uploading, .downloading, .merging:
            return "请稍候…"
        }
    }

    private var syncFooter: String {
        return "通过 GitHub 私有仓库同步数据。Token 与仓库路径仅存储在本机,不上传任何第三方。"
    }

    private func timeAgoString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        return "\(Int(interval / 86400)) 天前"
    }

    private var advancedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $bilibiliCookie)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .background(.gray.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 8))

                HStack {
                    Button("保存") {
                        AppSettings.bilibiliCookie = bilibiliCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                        BilibiliSessionManager.shared.reset()
                        Task {
                            loginState = await BilibiliSessionManager.shared.verifyLogin(force: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bilibiliCookie.trimmingCharacters(in: .whitespacesAndNewlines) == AppSettings.bilibiliCookie)

                    Button("清除") {
                        bilibiliCookie = ""
                        AppSettings.bilibiliCookie = ""
                        BilibiliSessionManager.shared.logout()
                        loginState = .loggedOut
                    }
                    .foregroundStyle(.red)

                    Spacer()

                    Button("如何获取？") {
                        showCookieHelp = true
                    }
                }
            }
        } header: {
            Text("手动 Cookie")
        } footer: {
            Text("仅在扫码不可用时使用。关键字段:SESSDATA。")
                .font(.caption2)
        }
        .alert("如何获取 B站 Cookie", isPresented: $showCookieHelp) {
            Button("知道了") {}
        } message: {
            Text("1. 在电脑浏览器打开 bilibili.com 并登录\n2. 按 F12 打开开发者工具\n3. 切换到 Network 标签\n4. 刷新页面,点击任意请求\n5. 在请求头中找到 Cookie 字段\n6. 复制整个 Cookie 值粘贴到上方\n\n关键要包含 SESSDATA 字段")
        }
    }
}
