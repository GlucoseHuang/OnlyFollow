import SwiftUI
import SwiftData

struct CreatorDetailView: View {
    let creator: FollowedCreator
    @ObservedObject private var cache = VideoCache.shared
    /// 用 @Query 监听播放列表，左滑加入/移除后按钮状态会自动刷新
    @Query private var playlistItems: [PlaylistItem]
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasMore = true
    @State private var nextPage = 1
    @State private var showFavorites = false
    @State private var showPlaylist = false
    @State private var showUnfollowConfirm = false
    /// 手动触发的 bulk fetch 任务（让用户一键补全该 UP 主历史视频）
    @State private var bulkFetchTask: Task<Void, Never>?
    @State private var isBulkFetching = false
    private let pageSize = 20
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// 直接访问 @Published 字典，让 SwiftUI 追踪依赖
    /// （之前用 cache.videos(for:) 方法调用不会被追踪，导致 cache 更新后 view 不会重渲染）
    private var videos: [VideoItem] { cache.videosByCreator[creator.uid] ?? [] }
    private var liveRoom: LiveRoom? { cache.liveRoom(for: creator.uid) }
    private var playlistAidSet: Set<Int> { Set(playlistItems.map(\.aid)) }

    var body: some View {
        List {
            // Header section: 头像 + 昵称 + 直播横幅
            Section {
                VStack(spacing: 16) {
                    creatorHeader
                    if let room = liveRoom, room.isLive {
                        liveBanner(room: room)
                    }
                    bulkFetchProgressSection
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if videos.isEmpty {
                Section {
                    emptyOrLoadingRow
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(videos) { video in
                    videoRow(for: video)
                }

                Section {
                    loadMoreRow
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(creator.nickname)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showFavorites = true } label: {
                        Label("我的收藏", systemImage: "star")
                    }
                    Button { showPlaylist = true } label: {
                        Label("播放列表", systemImage: "list.bullet.rectangle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showUnfollowConfirm = true
                    } label: {
                        Label("取消关注", systemImage: "person.crop.circle.badge.xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onDisappear {
            bulkFetchTask?.cancel()
            isBulkFetching = false
        }
        .confirmationDialog(
            "确定要取消关注「\(creator.nickname)」吗？",
            isPresented: $showUnfollowConfirm,
            titleVisibility: .visible
        ) {
            Button("取消关注", role: .destructive) { unfollow() }
            Button("再想想", role: .cancel) {}
        } message: {
            Text("将从首页移除该 UP 主，已缓存的视频数据保留。")
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesView()
        }
        .sheet(isPresented: $showPlaylist) {
            PlaylistView()
        }
        .task {
            // 缓存里有就直接展示，没有就拉首页
            if videos.isEmpty { await refresh() }
        }
    }

    @ViewBuilder
    private var emptyOrLoadingRow: some View {
        if isLoading {
            HStack {
                Spacer()
                ProgressView("加载中...")
                Spacer()
            }
            .padding(.vertical, 12)
        } else if let err = errorMessage {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else {
            Text("暂无视频")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var loadMoreRow: some View {
        if hasMore {
            Button {
                Task { await loadMore() }
            } label: {
                HStack {
                    if isLoadingMore { ProgressView().scaleEffect(0.7) }
                    Text(isLoadingMore ? "加载中..." : "加载更多")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .disabled(isLoadingMore)
        } else {
            Text("已经到底了")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private var creatorHeader: some View {
        HStack(spacing: 16) {
            AsyncImage(url: URL(string: ensureHTTPS(creator.avatarURL))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.3)
            }
            .frame(width: 60, height: 60)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(creator.nickname)
                    .font(.title3.bold())
                Text(creator.platform)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func liveBanner(room: LiveRoom) -> some View {
        NavigationLink {
            LiveRoomView(room: room)
        } label: {
            HStack {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text("正在直播: \(room.title)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)
                Spacer()
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.red)
            }
            .padding(12)
            .background(.red.opacity(0.1), in: .rect(cornerRadius: 10))
        }
    }

    /// 单个视频行：左滑 -> 加入播放列表
    private func videoRow(for video: VideoItem) -> some View {
        let inPlaylist = playlistAidSet.contains(video.aid)
        return NavigationLink {
            VideoPlayerView(video: video, modelContext: modelContext)
        } label: {
            CreatorVideoRow(video: video)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                addToPlaylist(video)
            } label: {
                Label(inPlaylist ? "已加入" : "加入播放列表", systemImage: "list.bullet.rectangle")
            }
            .tint(inPlaylist ? .gray : .blue)
        }
    }

    private func addToPlaylist(_ video: VideoItem) {
        guard !playlistAidSet.contains(video.aid) else { return }
        // order 设为当前最大 + 1
        let descriptor = FetchDescriptor<PlaylistItem>(sortBy: [SortDescriptor(\.order, order: .reverse)])
        let maxOrder = (try? modelContext.fetch(descriptor).first?.order) ?? -1
        modelContext.insert(PlaylistItem(video: video, order: maxOrder + 1))
        try? modelContext.save()
    }

    // MARK: - 数据加载

    private func refresh() async {
        isLoading = true
        errorMessage = nil
        nextPage = 1
        hasMore = true
        let api = BilibiliAPIService.shared
        do {
            switch creator.platform {
            case "bilibili":
                let info = try await api.fetchUserInfo(mid: creator.uid)
                if let live = info.liveRoom {
                    let room = LiveRoom(
                        id: "\(live.roomid)",
                        roomID: "\(live.roomid)",
                        title: live.title,
                        coverURL: ensureHTTPS(live.cover),
                        streamURL: live.url ?? "",
                        viewerCount: 0,
                        authorUID: creator.uid,
                        authorName: creator.nickname,
                        authorAvatar: ensureHTTPS(creator.avatarURL),
                        platform: "bilibili",
                        isLive: live.isLiving
                    )
                    cache.setLiveRoom(room, for: creator.uid)
                }

                let v = try await api.fetchUserVideos(mid: creator.uid, page: nextPage, pageSize: pageSize)
                cache.setVideos(v, for: creator.uid)
                hasMore = v.count >= pageSize
                nextPage = 2
            case "douyin":
                errorMessage = "抖音暂未支持"
            default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.error("CreatorDetail load failed: \(error.localizedDescription)")
        }
        isLoading = false
        AppLogger.info("CreatorDetail loaded: \(videos.count) videos")
    }

    // MARK: - 取消关注

    /// 只删 FollowedCreator 实体；缓存的 VideoItem / LiveRoom 保留（用户明确要求）
    private func unfollow() {
        AppLogger.info("Unfollow creator: uid=\(creator.uid), name=\(creator.nickname)")
        modelContext.delete(creator)
        try? modelContext.save()
        dismiss()
    }

    // MARK: - Bulk fetch 一键补全

    /// 当前 UP 主是否还需要补全历史
    private var needsBulkFetch: Bool {
        creator.bulkFetchCompletedAt == nil
    }

    /// 已在 cache 里的视频数 vs API 返回的总数
    private var bulkFetchProgress: (loaded: Int, total: Int) {
        let loaded = cache.videosByCreator[creator.uid]?.count ?? 0
        let total = max(creator.bulkFetchTotal, loaded)
        return (loaded, total)
    }

    private var bulkFetchProgressSection: some View {
        let p = bulkFetchProgress
        // 只有在"知道总数 + 未完成 + 总数大于当前 cache"时才显示
        if creator.bulkFetchTotal > 0 && needsBulkFetch && p.total > p.loaded {
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down")
                            .foregroundStyle(.blue)
                        Text("该 UP 主共 \(p.total) 个视频，已加载 \(p.loaded)")
                            .font(.caption)
                        Spacer()
                    }
                    Button {
                        startManualBulkFetch()
                    } label: {
                        HStack {
                            if isBulkFetching {
                                ProgressView().scaleEffect(0.8)
                                Text("补全中…")
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("立即补全历史")
                            }
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.blue.opacity(0.15), in: .rect(cornerRadius: 8))
                        .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBulkFetching)
                }
                .padding(10)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
            )
        }
        return AnyView(EmptyView())
    }

    /// 一键补全：循环跑 bulk fetch 直到完成或限流（最多 200 页 = 6000 视频，够绝大多数 UP 主）
    private func startManualBulkFetch() {
        bulkFetchTask?.cancel()
        isBulkFetching = true
        let context = modelContext
        bulkFetchTask = Task { @MainActor in
            let processed = await VideoSyncService.opportunisticBulkFetchLoop(
                in: context,
                maxPages: 200
            )
            AppLogger.info("CreatorDetailView: 手动补全 \(creator.nickname) 跑了 \(processed) 页")
            isBulkFetching = false
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let api = BilibiliAPIService.shared
        do {
            let more = try await api.fetchUserVideos(mid: creator.uid, page: nextPage, pageSize: pageSize)
            cache.appendVideos(more, for: creator.uid)
            hasMore = more.count >= pageSize
            nextPage += 1
        } catch {
            AppLogger.error("CreatorDetail loadMore failed: \(error.localizedDescription)")
        }
        isLoadingMore = false
    }
}

/// 详情页的视频行：左侧缩略图，右侧标题/播放量/日期
/// 设计原则：
/// - 缩略图固定 16:9 比例（按用户大字体情况放大到 180x101）
/// - 标题允许 3 行（之前 2 行在大字体下被截）
/// - 元数据拆成两行（播放量 + 日期），不再单行硬塞
struct CreatorVideoRow: View {
    let video: VideoItem
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: URL(string: video.coverURL)) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.gray.opacity(0.2) }
            // 16:9 缩略图，给标题腾出更多横向空间
            .frame(width: 180, height: 101)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                Text(formatDuration(video.duration))
                    .font(.caption2).bold()
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.black.opacity(0.7))
                    .foregroundStyle(.white)
                    .clipShape(.rect(cornerRadius: 4))
                    .padding(4)
            }

            VStack(alignment: .leading, spacing: 6) {
                // 标题：加粗，3 行内（之前 2 行在大字体下被截）
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // 元数据：拆成两行，单独一行不会被截断
                Label(formatViewCount(video.viewCount), systemImage: "play.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(formatDate(video.publishTime), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private func formatDuration(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    private func formatViewCount(_ n: Int) -> String {
        if n >= 10000 {
            return String(format: "%.1f万", Double(n) / 10000)
        }
        return "\(n)"
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        // 今年的就只写 MM-dd，节省横向空间
        if Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date()) {
            f.dateFormat = "MM-dd"
        } else {
            f.dateFormat = "yyyy-MM-dd"
        }
        return f.string(from: d)
    }
}
