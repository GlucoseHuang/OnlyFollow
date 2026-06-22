import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedPlatform: Platform = .bilibili
    /// 当前弹出的二级页面(取代 4 个独立 @State bool + 4 个 .sheet(isPresented:))
    /// 单 sheet 模式:iOS 17/18 SwiftUI 在同一视图堆多个 sheet 时 toolbar 按钮的 hit-test
    /// 会明显延迟("点 + 按钮要点几下才出弹窗"),统一一个 .sheet(item:) 就没这毛病
    @State private var activeSheet: ActiveSheet?
    @State private var loginState: BilibiliLoginState = .unknown
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    /// 同步状态（订阅 SyncCoordinator 变更）
    @ObservedObject private var syncCoordinator = SyncCoordinator.shared
    /// 后台拉取任务：每次 scenePhase 切到 .active 时取消上一个再 spawn 新的
    @State private var syncTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            PlatformTabView(selectedPlatform: $selectedPlatform, onRequestLogin: { activeSheet = .login })
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // 点开是 menu：扫码登录 B 站 / 同步设置
                        // （登录状态颜色保留在 icon 上作为提示）
                        Menu {
                            Button {
                                activeSheet = .login
                            } label: {
                                Label("扫码登录 B站", systemImage: "qrcode.viewfinder")
                            }
                            Button {
                                activeSheet = .douyinLogin
                            } label: {
                                Label("扫码登录抖音", systemImage: "qrcode")
                            }
                            Button {
                                activeSheet = .settings
                            } label: {
                                Label("同步设置", systemImage: "arrow.triangle.2.circlepath")
                            }
                        } label: {
                            Image(systemName: loginIcon)
                                .foregroundStyle(loginColor)
                        }
                        .accessibilityLabel(loginAccessibility)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            activeSheet = .search
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("搜索视频")
                        Button {
                            activeSheet = .addFollow
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("添加关注")
                    }
                }
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .addFollow:
                        AddFollowView { _ in
                            // 新增关注后立刻触发一次同步,避免"sheet 关闭不触发 scenePhase"的 UX 缺口
                            triggerBackgroundSync()
                        }
                    case .login:
                        LoginView(isPresented: Binding(
                            get: { activeSheet == .login },
                            set: { if !$0 { activeSheet = nil } }
                        ))
                    case .douyinLogin:
                        DouyinLoginView(isPresented: Binding(
                            get: { activeSheet == .douyinLogin },
                            set: { if !$0 { activeSheet = nil } }
                        ))
                    case .settings:
                        NavigationStack {
                            SettingsView()
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("关闭") { activeSheet = nil }
                                    }
                                }
                        }
                    case .search:
                        VideoSearchView()
                    }
                }
        }
        .task {
            // 把 modelContext 注入同步协调器（上传 / 拉取都靠它）
            SyncCoordinator.shared.attachModelContext(modelContext)
            // 启动时静默验证一次登录态 + 首次请求通知权限
            loginState = await BilibiliSessionManager.shared.verifyLogin()
            await NotificationService.shared.requestAuthorizationIfNeeded()
            // 启动后立刻从 iCloud 拉一次（如果 iPhone 上加过东西，iPad 启动时就能看到）
            await SyncCoordinator.shared.pullNow()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // App 切到前台时启动一次后台同步：增量刷新 + 顺手推进一步批量拉取
            // 系统自带限流在 BilibiliAPIService 内（3s + 指数退避），多次切前台不会爆
            if newPhase == .active {
                triggerBackgroundSync()
                // 回前台从 iCloud 拉一次（你点出的「启动时看看文件更新时间」诉求）
                Task { await SyncCoordinator.shared.pullNow() }
            } else if newPhase == .background {
                // App 退后台：强制 flush 一次（避免丢最后一波改动）
                SyncCoordinator.shared.flushPending()
            }
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: BilibiliSessionManager.loginStateDidChangeNotification)
                .receive(on: RunLoop.main)
        ) { note in
            if let state = note.object as? BilibiliLoginState {
                loginState = state
            }
        }
    }

    private func triggerBackgroundSync() {
        // 注意：这里不取消上一个 syncTask。之前每个 AddFollowView 关闭都 cancel 上一个，
        // 导致用户连续添加 UP 主时第一轮同步一个都没跑成功。
        // API 限流在 BilibiliAPIService 内部（3s + 指数退避），多个 Task 并发会被自然串行化。
        let context = modelContext
        syncTask = Task {
            // 1) 拉所有 B 站 creator（platform filter）
            // 同时拉 B 站 + 抖音,VideoSyncService.performIncrementalRefresh 内部按 platform 分流
            let descriptor = FetchDescriptor<FollowedCreator>()
            let creators = (try? context.fetch(descriptor)) ?? []
            // 2) 首次进入时把 bulkFetchNextPage 兜底成 2
            VideoSyncService.ensureBulkFetchInitialized(creators: creators, in: context)
            // 3) 增量刷新
            let result = await VideoSyncService.performIncrementalRefresh(creators: creators, in: context)
            AppLogger.info("ContentView: scenePhase active 同步完成 \(result.refreshed) creator, \(result.notified) 通知")
            // 4) bulk fetch 循环（每次 foreground 跑 10 页 ≈ 35s；命中 -799 限流会自动停）
            let processed = await VideoSyncService.opportunisticBulkFetchLoop(in: context, maxPages: 10)
            if processed > 0 {
                AppLogger.info("ContentView: bulk fetch 本轮跑了 \(processed) 页")
            }
        }
    }

    private var loginIcon: String {
        switch loginState {
        case .loggedIn: return "person.crop.circle.fill"
        case .loggedOut: return "person.crop.circle.badge.exclamationmark"
        case .unknown: return "person.crop.circle"
        }
    }

    private var loginColor: Color {
        switch loginState {
        case .loggedIn: return .green
        case .loggedOut: return .orange
        case .unknown: return .secondary
        }
    }

    private var loginAccessibility: String {
        switch loginState {
        case .loggedIn(_, let name): return "已登录 \(name)"
        case .loggedOut: return "未登录，点击扫码登录"
        case .unknown: return "登录状态未知"
        }
    }
}

enum Platform: String, CaseIterable {
    case bilibili = "bilibili"
    case douyin = "douyin"

    var displayName: String {
        switch self {
        case .bilibili: return "B站"
        case .douyin: return "抖音"
        }
    }

    var iconName: String {
        switch self {
        case .douyin: return "music.note"
        case .bilibili: return "play.tv"
        }
    }
}

// MARK: - Sheet 路由

/// ContentView 顶层唯一的 sheet 路由类型。Identifiable + 单 .sheet(item:) 的组合,
/// 既能给 SwiftUI 一个稳定的 id 用来 diff/动画,又能避免在同一视图堆叠多个 .sheet(isPresented:)
/// 时 hit-test 出问题("+ 按钮要点几下才出弹窗"的根因)。
enum ActiveSheet: Identifiable {
    case addFollow
    case login
    case douyinLogin
    case settings
    case search

    var id: String {
        switch self {
        case .addFollow: return "addFollow"
        case .login: return "login"
        case .douyinLogin: return "douyinLogin"
        case .settings: return "settings"
        case .search: return "search"
        }
    }
}
