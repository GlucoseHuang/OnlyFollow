import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedPlatform: Platform = .bilibili
    @State private var showAddFollow = false
    @State private var showLogin = false
    @State private var showSearch = false
    @State private var loginState: BilibiliLoginState = .unknown
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    /// 后台拉取任务：每次 scenePhase 切到 .active 时取消上一个再 spawn 新的
    @State private var syncTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            PlatformTabView(selectedPlatform: $selectedPlatform, showLogin: $showLogin)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showLogin = true
                        } label: {
                            Image(systemName: loginIcon)
                                .foregroundStyle(loginColor)
                        }
                        .accessibilityLabel(loginAccessibility)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("搜索视频")
                        Button {
                            showAddFollow = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("添加关注")
                    }
                }
                .sheet(isPresented: $showAddFollow) {
                    AddFollowView { _ in
                        // 新增关注后立刻触发一次同步，避免「sheet 关闭不触发 scenePhase」的 UX 缺口
                        triggerBackgroundSync()
                    }
                }
                .sheet(isPresented: $showLogin) {
                    LoginView(isPresented: $showLogin)
                }
                .sheet(isPresented: $showSearch) {
                    VideoSearchView()
                }
        }
        .task {
            // 启动时静默验证一次登录态 + 首次请求通知权限
            loginState = await BilibiliSessionManager.shared.verifyLogin()
            await NotificationService.shared.requestAuthorizationIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // App 切到前台时启动一次后台同步：增量刷新 + 顺手推进一步批量拉取
            // 系统自带限流在 BilibiliAPIService 内（3s + 指数退避），多次切前台不会爆
            if newPhase == .active {
                triggerBackgroundSync()
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
            let descriptor = FetchDescriptor<FollowedCreator>(
                predicate: #Predicate { $0.platform == "bilibili" }
            )
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
