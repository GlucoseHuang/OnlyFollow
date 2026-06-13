import SwiftUI
import SwiftData

struct PlatformTabView: View {
    @Binding var selectedPlatform: Platform
    @Binding var showLogin: Bool
    @Query private var creators: [FollowedCreator]
    @Environment(\.modelContext) private var modelContext

    @ObservedObject private var cache = VideoCache.shared
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loginState: BilibiliLoginState = .unknown
    @State private var showFavorites = false
    @State private var showPlaylist = false
    @State private var showHistory = false
    /// .refreshable 在某些情况下会被 SwiftUI 取消它的 Task，
    /// 所以真正的工作放在这里 spawn 的独立 Task 里——它不继承 .refreshable 的取消链。
    @State private var refreshTask: Task<Void, Never>?

    private var filteredCreators: [FollowedCreator] {
        creators.filter { $0.platform == selectedPlatform.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            mineEntryRow
            platformPicker

            if selectedPlatform == .bilibili, needsLoginBanner {
                loginBanner
            }

            if filteredCreators.isEmpty {
                emptyView
            } else {
                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red).padding(.vertical, 4)
                }

                ScrollView {
                    LazyVStack(spacing: 12) {
                        let liveCreators = filteredCreators.filter { cache.liveRoom(for: $0.uid)?.isLive == true }
                        if !liveCreators.isEmpty {
                            Section {
                                ForEach(liveCreators) { creator in
                                    if let room = cache.liveRoom(for: creator.uid) {
                                        LiveRoomCard(room: room)
                                    }
                                }
                            } header: {
                                HStack {
                                    Circle().fill(.red).frame(width: 8, height: 8)
                                    Text("正在直播").font(.headline)
                                }
                            }
                        }

                        Section {
                            ForEach(filteredCreators) { creator in
                                CreatorRow(
                                    creator: creator,
                                    liveRoom: cache.liveRoom(for: creator.uid),
                                    videos: cache.videos(for: creator.uid) ?? [],
                                    isLoading: isLoading && (cache.videos(for: creator.uid) == nil)
                                )
                            }
                        } header: {
                            if !liveCreators.isEmpty {
                                Text("全部关注").font(.headline)
                            }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    // 不 await，让工作跑在脱离 .refreshable 取消链的独立 Task 里
                    refreshTask?.cancel()
                    refreshTask = Task { @MainActor in
                        await refreshData()
                    }
                }
            }
        }
        .navigationTitle("我的关注")
        .overlay {
            if isLoading && (cache.videosByCreator.isEmpty) && !filteredCreators.isEmpty {
                ProgressView("首次加载中...")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        .task {
            // 缓存策略：磁盘里有就直接用，不自动重拉。
            // 第一次安装（磁盘也是空的）才去拉。
            let hasAnyCache = !cache.videosByCreator.isEmpty
            if !hasAnyCache { await refreshData() }
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesView()
        }
        .sheet(isPresented: $showPlaylist) {
            PlaylistView()
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
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

    /// 顶部三个入口：⭐ 收藏 / ▶ 播放列表 / 🕘 历史
    private var mineEntryRow: some View {
        HStack(spacing: 10) {
            Button { showFavorites = true } label: {
                Label("收藏", systemImage: "star.fill")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.yellow.opacity(0.15), in: .rect(cornerRadius: 8))
                    .foregroundStyle(.orange)
            }
            Button { showPlaylist = true } label: {
                Label("播放列表", systemImage: "list.bullet.rectangle.fill")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.blue.opacity(0.15), in: .rect(cornerRadius: 8))
                    .foregroundStyle(.blue)
            }
            Button { showHistory = true } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.15), in: .rect(cornerRadius: 8))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// 批量拉取进度（B 站 creator 的补全状态）
    /// - 触发重渲染：@Query creators，任一 creator 的 bulkFetchCompletedAt 变化都会更新
    private var bulkFetchProgress: (done: Int, total: Int) {
        let bili = creators.filter { $0.platform == "bilibili" }
        let done = bili.filter { $0.bulkFetchCompletedAt != nil }.count
        return (done, bili.count)
    }

    /// 批量拉取进度横幅：只在 B 站 tab + 有 pending 工作时显示
    @ViewBuilder
    private var bulkFetchProgressBanner: some View {
        if selectedPlatform == .bilibili {
            let p = bulkFetchProgress
            if p.total > 0 && p.done < p.total {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.blue)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在补全历史 \(p.done) / \(p.total)").font(.caption).bold()
                        Text("搜索覆盖范围会随补全扩大").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressView().scaleEffect(0.7)
                }
                .padding(10)
                .background(.blue.opacity(0.1), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.blue.opacity(0.3), lineWidth: 0.5))
                .padding(.horizontal)
                .padding(.top, 6)
            }
        }
    }

    private var platformPicker: some View {
        VStack(spacing: 8) {
            Picker("平台", selection: $selectedPlatform) {
                ForEach(Platform.allCases, id: \.self) { p in
                    Label(p.displayName, systemImage: p.iconName).tag(p)
                }
            }
            .pickerStyle(.segmented)

            bulkFetchProgressBanner
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var loginBanner: some View {
        Button {
            showLogin = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "qrcode")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bannerTitle).font(.subheadline).bold()
                    Text(bannerSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.orange.opacity(0.15), in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.orange.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var needsLoginBanner: Bool {
        if case .loggedIn = loginState { return false }
        if case .unknown = loginState { return false }
        return true
    }

    private var bannerTitle: String {
        if case .loggedOut = loginState { return "未登录 B 站账号" }
        return "扫码登录 B 站"
    }

    private var bannerSubtitle: String {
        if case .loggedOut = loginState { return "登录后可以查看关注 UP 主的最新视频" }
        return "扫码后可立即查看最新视频"
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text("还没有关注的 UP 主")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("点击右上角 + 添加")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func refreshData() async {
        let targets = filteredCreators
        guard !targets.isEmpty else { return }
        isLoading = true
        errorMessage = nil

        // 委托给 VideoSyncService：拉首页 → 写入 VideoRecord（可搜索）→ 写 VideoCache（首页用）→ 检测新增 → 发通知
        // 限流 / 风控的语义跟原来一致：命中就提前停
        let result = await VideoSyncService.performIncrementalRefresh(creators: targets, in: modelContext)

        if result.hitAntiCrawler {
            errorMessage = "B站风控挑战，请等待几秒后下拉刷新（首次扫码登录后可能需要 30~60s 冷却）"
        } else if result.hitRateLimit {
            errorMessage = "请求过于频繁，请稍后下拉刷新"
        } else if result.refreshed == 0 && !targets.isEmpty {
            errorMessage = "本次刷新未成功，请稍后再试"
        }

        isLoading = false
        AppLogger.info("Refresh done: refreshed=\(result.refreshed), notified=\(result.notified)")
    }
}

struct CreatorRow: View {
    let creator: FollowedCreator
    let liveRoom: LiveRoom?
    let videos: [VideoItem]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: ensureHTTPS(creator.avatarURL))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.3)
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(creator.nickname).font(.subheadline.bold())
                        if let room = liveRoom, room.isLive {
                            HStack(spacing: 3) {
                                Circle().fill(.red).frame(width: 6, height: 6)
                                Text("直播中").font(.caption2).bold()
                            }
                            .foregroundStyle(.red)
                        }
                    }
                }

                Spacer()

                NavigationLink {
                    CreatorDetailView(creator: creator)
                } label: {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }

            if isLoading {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("加载中...").font(.caption).foregroundStyle(.secondary)
                }
            } else if !videos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(videos) { video in
                            VideoThumbnail(video: video)
                        }
                    }
                }
            } else {
                Text("暂无视频").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}
