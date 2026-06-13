import SwiftUI
import AVKit
import SwiftData

/// 全屏视频播放页（自定义 UI）：
/// - 顶部：关闭 + 标题
/// - 中部：视频 + 弹幕（可切换）
/// - 右侧：锁定屏幕按钮
/// - 底部：进度条 + 播放/暂停 + 全屏 + 弹幕开关 + 评论
///
/// 切歌逻辑：所有 UI 元素都绑定到 `vm.video`（会在 switchVideo 时更新），
/// 而不是 view 自己的 let `video`，这样切歌后标题/UP主/弹幕/评论/收藏状态都会自动刷新。
struct VideoPlayerView: View {
    let video: VideoItem
    /// 播放列表（可选）：从 playlist 进入时传入，播完自动下一个
    var playlist: [VideoItem] = []
    var playlistStartIndex: Int = 0
    @StateObject private var vm: VideoPlayerViewModel
    @State private var showComments = false
    @State private var playlistIndex: Int
    @State private var isLocked: Bool = false
    /// 定时关闭剩余秒数；nil 表示未启用
    @State private var sleepRemainingSeconds: Int?
    @State private var sleepTimerTask: Task<Void, Never>?
    /// 周期保存进度的后台任务（每 5 秒一次）
    @State private var progressSaveTask: Task<Void, Never>?
    /// 显式传入的 ModelContext：PlayerPresenter 走 UIKit present 时 @Environment(\.modelContext)
    /// 拿不到，必须由调用方传进来；NavigationLink / sheet 路径也传，方便行为一致
    let modelContext: ModelContext
    @Environment(\.dismiss) private var dismiss

    init(video: VideoItem, modelContext: ModelContext, playlist: [VideoItem] = [], playlistStartIndex: Int = 0) {
        self.video = video
        self.modelContext = modelContext
        self.playlist = playlist
        self.playlistStartIndex = playlistStartIndex
        _vm = StateObject(wrappedValue: VideoPlayerViewModel(video: video))
        // 直接用初始 index 初始化 State，避开 .task 里赋值导致后续 remount 被重置
        _playlistIndex = State(initialValue: playlistStartIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = vm.avPlayer {
                AVPlayerLayerView(player: player)
                    .ignoresSafeArea()
            }

            if vm.danmakuEnabled {
                // 弹幕铺满整个屏幕：滚动 + 顶部弹幕活动区限制在屏幕顶部 1/4，底部弹幕定位到屏幕最底端。
                GeometryReader { geo in
                    DanmakuFloatingView(
                        danmakuList: vm.allDanmaku,
                        currentVideoTime: vm.currentTime,
                        lastUpdateWallTime: vm.currentTimeUpdatedAt,
                        isPlaying: vm.isPlaying,
                        activityHeight: geo.size.height / 4
                    )
                }
                .ignoresSafeArea()
            }

            if let err = vm.loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50)).foregroundStyle(.white)
                    Text(err).foregroundStyle(.white).padding()
                }
            }

            if vm.showControls && !isLocked {
                controlsOverlay
                    .transition(.opacity)
            }

            // 锁定屏幕按钮：右侧中部，独立于 controlsOverlay 之外
            // 锁定后双击/单击不响应，控件也会被隐藏
            lockButton
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(vm.isFullscreen)
        .toolbar(vm.isFullscreen ? .hidden : .visible, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .ignoresSafeArea(vm.isFullscreen ? .all : .container, edges: .all)
        // 双击切播放/暂停。lock 时不响应。
        // 注意：必须放在 onTapGesture（单击）之前，否则 SwiftUI 会把单击也当成双击处理
        .onTapGesture(count: 2) {
            guard !isLocked else { return }
            vm.togglePlay()
        }
        // 单击：显示/隐藏控件
        .onTapGesture {
            guard !isLocked else { return }
            vm.tapSurface()
        }
        .task {
            // 1. 从 PlaybackHistory 读出上次的播放进度，准备续播
            let aid = vm.video.aid
            let descriptor = FetchDescriptor<PlaybackHistory>(predicate: #Predicate { $0.aid == aid })
            if let existing = try? modelContext.fetch(descriptor).first,
               existing.progressSeconds > 5 {
                vm.initialResumeSeconds = Double(existing.progressSeconds)
                AppLogger.info("Player: history found, will resume from \(existing.progressSeconds)s")
            }

            // 2. 装好播放结束回调：当前视频播完时自动连播下一个
            vm.onCurrentVideoEnd = { [weak vm] in
                guard let vm else { return }
                advancePlaylistIfNeeded(vm: vm)
            }

            // 3. 启动播放（load 完成后会按 initialResumeSeconds 自动 seek）
            await vm.load()

            // 4. 启动周期保存任务（每 5 秒一次）
            progressSaveTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if Task.isCancelled { break }
                    saveProgress()
                }
            }
        }
        .onAppear { syncFavorite() }
        // 切歌后：vm.video 改变 → 重新同步收藏状态、刷新评论 sheet
        .onChange(of: vm.video.aid) { _, _ in
            syncFavorite()
        }
        .onChange(of: vm.isFavorited) { _, newValue in
            applyFavoriteChange(newValue)
        }
        .onDisappear {
            progressSaveTask?.cancel()
            sleepTimerTask?.cancel()
            saveProgress()
            vm.avPlayer?.pause()
            if vm.isFullscreen { AppOrientationHelper.setOrientation(.portrait) }
        }
        // 用 vm.video.aid 作为 sheet 内容标识，切歌时强制重开（重置 a fresh sheet）
        .sheet(isPresented: $showComments) {
            CommentsSheet(aid: "\(vm.video.aid)")
                .id(vm.video.aid)
        }
    }

    // MARK: - 控件层

    private var controlsOverlay: some View {
        VStack {
            topBar
            Spacer()
            if vm.danmakuEnabled {
                Spacer().frame(height: 60)
            }
            bottomBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.3), in: .circle)
            }
            VStack(alignment: .leading, spacing: 2) {
                // 绑定到 vm.video，切歌后自动更新
                Text(vm.video.title).font(.subheadline.bold()).foregroundStyle(.white).lineLimit(1)
                Text(vm.video.authorName).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button { vm.toggleDanmaku() } label: {
                Image(systemName: vm.danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                    .font(.title3)
                    .foregroundStyle(vm.danmakuEnabled ? .yellow : .white)
                    .padding(8)
                    .background(.black.opacity(0.3), in: .circle)
            }
            Button { vm.toggleFavorite() } label: {
                Image(systemName: vm.isFavorited ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(vm.isFavorited ? .yellow : .white)
                    .padding(8)
                    .background(.black.opacity(0.3), in: .circle)
            }
            Button { showComments = true } label: {
                Image(systemName: "ellipsis.bubble")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.3), in: .circle)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(formatTime(vm.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                Slider(
                    value: Binding(
                        get: { vm.currentTime },
                        set: { vm.seek(to: $0) }
                    ),
                    in: 0...max(vm.duration, 1)
                )
                .tint(.white)
                Text(formatTime(vm.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }

            HStack(spacing: 24) {
                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                }
                Spacer()
                if vm.quality > 0 {
                    Text("清晰度 \(qualityLabel(vm.quality))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Button { vm.toggleFullscreen() } label: {
                    Image(systemName: vm.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                sleepTimerButton
            }
        }
    }

    /// 锁定屏幕按钮：屏幕右侧中部
    /// 锁定时切图标为解锁，再点回到 unlock
    private var lockButton: some View {
        VStack {
            Spacer()
            Button {
                isLocked.toggle()
            } label: {
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.3), in: .circle)
            }
            .padding(.trailing, 16)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .allowsHitTesting(true)
    }

    private func qualityLabel(_ q: Int) -> String {
        switch q {
        case 16: return "360P"
        case 32: return "480P"
        case 64: return "720P"
        case 80: return "1080P"
        case 112: return "1080P+"
        case 116: return "4K"
        default: return "\(q)P"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - 收藏

    private func syncFavorite() {
        let aid = vm.video.aid
        let descriptor = FetchDescriptor<FavoriteVideo>(
            predicate: #Predicate { $0.aid == aid }
        )
        if let existing = try? modelContext.fetch(descriptor), !existing.isEmpty {
            vm.isFavorited = true
        } else {
            vm.isFavorited = false
        }
    }

    // MARK: - 历史 / 进度保存

    /// 把当前播放进度写入 PlaybackHistory。
    /// - 已存在条目：更新 progressSeconds + watchedAt（顺手同步 title/cover/duration）
    /// - 不存在条目：仅在真的看了一会儿（>=3s）才插入
    private func saveProgress() {
        let aid = vm.video.aid
        let progress = Int(vm.currentTime)
        let descriptor = FetchDescriptor<PlaybackHistory>(predicate: #Predicate { $0.aid == aid })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.progressSeconds = progress
            existing.watchedAt = Date()
            existing.title = vm.video.title
            existing.coverURL = vm.video.coverURL
            existing.duration = vm.video.duration
        } else if progress >= 3 {
            modelContext.insert(PlaybackHistory(video: vm.video, progressSeconds: progress))
        } else {
            return
        }
        try? modelContext.save()
    }

    // MARK: - 定时关闭

    /// 倒计时显示用的按钮：未启动时是月亮图标，启动后是"剩余 MM:SS"胶囊
    private var sleepTimerButton: some View {
        Menu {
            Button("15 分钟") { startSleepTimer(minutes: 15) }
            Button("30 分钟") { startSleepTimer(minutes: 30) }
            if sleepRemainingSeconds != nil {
                Divider()
                Button("关闭定时", role: .destructive) { cancelSleepTimer() }
            }
        } label: {
            if let remaining = sleepRemainingSeconds {
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz.fill")
                    Text(formatCountdown(remaining))
                        .monospacedDigit()
                }
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.18), in: .capsule)
            } else {
                Image(systemName: "moon.zzz")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
    }

    private func startSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        let total = minutes * 60
        sleepRemainingSeconds = total
        sleepTimerTask = Task { @MainActor in
            var remaining = total
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
                sleepRemainingSeconds = remaining
            }
            // 时间到：暂停播放（保留页面，方便用户手动继续或退出）
            vm.avPlayer?.pause()
            vm.isPlaying = false
            sleepRemainingSeconds = nil
            AppLogger.info("Player: sleep timer expired, paused")
        }
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepRemainingSeconds = nil
    }

    private func formatCountdown(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - 收藏

    private func applyFavoriteChange(_ isFav: Bool) {
        let aid = vm.video.aid
        let descriptor = FetchDescriptor<FavoriteVideo>(
            predicate: #Predicate { $0.aid == aid }
        )
        if isFav {
            if let existing = try? modelContext.fetch(descriptor), !existing.isEmpty { return }
            modelContext.insert(FavoriteVideo(video: vm.video))
        } else {
            if let existing = try? modelContext.fetch(descriptor) {
                for f in existing { modelContext.delete(f) }
            }
        }
        try? modelContext.save()
    }

    // MARK: - 播放列表自动连播

    private func advancePlaylistIfNeeded(vm: VideoPlayerViewModel? = nil) {
        let targetVM = vm ?? self.vm
        guard !playlist.isEmpty else { return }
        let nextIndex = playlistIndex + 1
        guard nextIndex < playlist.count else {
            // 播完最后一个就停
            AppLogger.info("Player: playlist ended at index \(playlistIndex)/\(playlist.count - 1)")
            return
        }
        AppLogger.info("Player: advancing to playlist[\(nextIndex)]")
        playlistIndex = nextIndex
        targetVM.switchVideo(playlist[nextIndex])
    }
}
