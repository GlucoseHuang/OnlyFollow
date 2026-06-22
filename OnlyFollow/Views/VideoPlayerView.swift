import SwiftUI
import AVKit
import SwiftData
import MediaPlayer

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
    /// 整个加载+控制中心注册流程的任务句柄，onDisappear 里取消以防 view 已不在时还继续拉接口
    @State private var loadTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss

    /// 合集/AI 推荐/「播完后推荐」浮层状态
    @State private var showSeasonList: Bool = false
    @State private var showRecommendationPage: Bool = false
    /// 分P 列表 sheet(同 BV 号下的多个段落, 与合集是不同概念)
    @State private var showPartList: Bool = false

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
                // 弹幕需要跟 topBar 视觉平齐：都不越过安全区。
                // 不再 .ignoresSafeArea()：弹幕 top 与 topBar 顶部对齐（都从 status bar 下面开始），
                // 弹幕底部自然停在 home indicator 之上。
                // activityHeight 用 safe area 高度算"顶部 1/4 活动区"，比之前略小但视觉无感。
                GeometryReader { geo in
                    DanmakuFloatingView(
                        danmakuList: vm.allDanmaku,
                        currentVideoTime: vm.currentTime,
                        lastUpdateWallTime: vm.currentTimeUpdatedAt,
                        isPlaying: vm.isPlaying,
                        activityHeight: geo.size.height / 4
                    )
                }
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
        // 顶层不忽略 safe area：让顶部 / 底部的控件自然落在安全区里，不与状态栏 / Home indicator 重叠。
        // 视频和弹幕层内部各自 .ignoresSafeArea()，保证画面仍能铺满全屏。
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
            // 整个 load + 控制中心注册流程放到 loadTask 里。
            // onDisappear 会显式 cancel 这个 task，load() 里的 await 就会抛 CancellationError 退出，
            // 不会在 view 已经消失后还继续创建出 player.play() 制造“关了页面还能听到声音”。
            loadTask = Task {
                // 0. 把 modelContext 注入 vm(让合集/推荐能用)
                vm.modelContext = modelContext

                // 1. 从 PlaybackHistory 读出上次的播放进度，准备续播
                let aid = vm.video.aid
                let descriptor = FetchDescriptor<PlaybackHistory>(predicate: #Predicate { $0.aid == aid })
                if let existing = try? modelContext.fetch(descriptor).first,
                   existing.progressSeconds > 5 {
                    vm.initialResumeSeconds = Double(existing.progressSeconds)
                    // 如果历史里记了上次看的分 P, 记下 cid 让 load() 完成后跳过去
                    // - 只有多 P 视频才需要切; 单 P 视频 / cid=0 都不切
                    if existing.partCid > 0 {
                        vm.resumePartCid = existing.partCid
                    }
                    AppLogger.info("Player: history found, will resume from \(existing.progressSeconds)s (partCid=\(existing.partCid), partPage=\(existing.partPage))")
                }

                // 2. 装好播放结束回调：当前视频播完时按「手动 playlist → 合集 → 推荐页」优先级处理
                vm.onCurrentVideoEnd = { [weak vm] in
                    guard let vm else { return }
                    handleVideoEnd(vm: vm)
                }

                // 3. 启动播放（load 完成后会按 initialResumeSeconds 自动 seek）
                await vm.load()

                // 4. 启动周期保存任务（每 5 秒一次）
                progressSaveTask = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                        if Task.isCancelled { break }
                        saveProgress()
                        refreshNowPlayingElapsed()
                    }
                }

                // 注册控制中心/锁定屏 widget:play / pause / togglePlayPause / next / prev
                let np = NowPlayingController.shared
                np.onPlay = { [weak vm] in
                    guard let vm, !vm.isPlaying else { return }
                    vm.togglePlay()
                }
                np.onPause = { [weak vm] in
                    guard let vm, vm.isPlaying else { return }
                    vm.togglePlay()
                }
                np.onTogglePlayPause = { [weak vm] in vm?.togglePlay() }
                np.onNextTrack = { advancePlaylistIfNeeded() }
                np.onPreviousTrack = { goToPreviousPlaylistItem() }
                np.hasNextTrack = canAdvanceNext
                np.hasPreviousTrack = canAdvancePrev
                np.register()
                pushNowPlayingMetadata()  // 首次写入
            }
            await loadTask?.value
        }
        .onAppear { syncFavorite() }
        // 切歌后：vm.video 改变 → 重新同步收藏状态、刷新评论 sheet、推 Now Playing 元数据
        .onChange(of: vm.video.aid) { _, _ in
            syncFavorite()
            let np = NowPlayingController.shared
            np.hasNextTrack = canAdvanceNext
            np.hasPreviousTrack = canAdvancePrev
            pushNowPlayingMetadata()
        }
        // season 列表变化（异步拉回）→ 同步「下一首」状态（控制中心按钮）
        .onChange(of: vm.seasonPlaylist) { _, _ in
            let np = NowPlayingController.shared
            np.hasNextTrack = canAdvanceNext
            np.hasPreviousTrack = canAdvancePrev
        }
        .onChange(of: vm.isFavorited) { _, newValue in
            applyFavoriteChange(newValue)
        }
        // 播放/暂停状态变 → 把 rate 同步到控制中心(否则锁定屏图标不刷新)
        .onChange(of: vm.isPlaying) { _, isPlaying in
            pushNowPlayingMetadata(rateOverride: isPlaying ? 1.0 : 0.0)
        }
        .onDisappear {
            progressSaveTask?.cancel()
            sleepTimerTask?.cancel()
            saveProgress()
            vm.avPlayer?.pause()
            // 取消仍在跑的 load 任务（防止“快速退出后 load 还在跑，创建出新的 player 并开始播”）。
            // tearDown 内部会 set isCancelled + remove observers + nil 出 player + 关闭音频会话，
            // 这样后面 load() 不会在 view 已经不在的情况下调 player.play()。
            loadTask?.cancel()
            loadTask = nil
            vm.tearDown()
            if vm.isFullscreen { AppOrientationHelper.setOrientation(.portrait) }
            // 关掉控制中心 widget 的命令绑定 + 清掉元数据
            NowPlayingController.shared.unregister()
        }
        // 用 vm.video.aid 作为 sheet 内容标识，切歌时强制重开（重置 a fresh sheet）
        .sheet(isPresented: $showComments) {
            CommentsSheet(videoId: vm.video.platform == "douyin" ? vm.video.id : "\(vm.video.aid)", platform: vm.video.platform)
                .id(vm.video.aid)
        }
        // 分P 视频列表(同 BV 号下的多个段落)
        // - 用 vm.video.aid 当 sheet id, 切歌时强制重开（合集 / 单 P 切到多 P 视频时也能正确刷新）
        .sheet(isPresented: $showPartList) {
            PartListSheet(
                videoTitle: vm.video.title,
                parts: vm.parts ?? [],
                currentIndex: vm.currentPartIndex,
                onSelect: { pickedIndex in
                    showPartList = false
                    vm.switchToPart(at: pickedIndex)
                }
            )
            .id("part-\(vm.video.aid)")
        }
        // 合集视频列表
        .sheet(isPresented: $showSeasonList) {
            SeasonListSheet(
                meta: vm.seasonMeta,
                videos: vm.seasonPlaylist ?? [],
                currentAid: vm.video.aid,
                onSelect: { picked in
                    showSeasonList = false
                    guard picked.aid != vm.video.aid else { return }
                    if let idx = vm.seasonPlaylist?.firstIndex(where: { $0.aid == picked.aid }) {
                        vm.seasonCurrentIndex = idx
                    }
                    vm.switchVideo(picked)
                },
                modelContext: modelContext,
                onBackfillComplete: { n in
                    if n > 0 {
                        vm.refreshSeasonPlaylist()
                    }
                },
                backfillMid: vm.video.authorUID,
                backfillSeasonID: vm.seasonMeta?.seasonID ?? 0
            )
        }
        // 「播完后推荐」视频页
        .sheet(isPresented: $showRecommendationPage) {
            RecommendationSheet(
                currentVideo: vm.video,
                recommendations: vm.pendingRecommendations ?? [],
                onSelect: { picked in
                    showRecommendationPage = false
                    vm.switchVideo(picked)
                }
            )
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
                // 多 P 视频: 显示「P3/15 · 分P标题」一行 + 作者名一行
                // 单 P 视频: 维持原状(视频标题 + 作者名)
                if vm.hasMultipleParts, let part = vm.currentPart {
                    Text("\(part.page) / \(vm.parts?.count ?? 0) · \(part.part)")
                        .font(.subheadline.bold()).foregroundStyle(.white).lineLimit(1)
                } else {
                    Text(vm.video.title).font(.subheadline.bold()).foregroundStyle(.white).lineLimit(1)
                }
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
            // 分P入口：仅当该视频是分P视频时显示(用 rectangle.stack.fill, 跟合集的 square.stack.3d.up.fill 视觉区分)
            if vm.hasMultipleParts {
                Button {
                    showPartList = true
                } label: {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.3), in: .circle)
                }
                .accessibilityLabel("分P列表")
            }
            // 合集入口(路径 1)：仅当该视频在合集里(ugcSeasonID > 0)时显示
            if (vm.video.ugcSeasonID ?? 0) > 0 {
                Button {
                    showSeasonList = true
                } label: {
                    if vm.isFetchingSeason {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                }
                .padding(8)
                .background(.black.opacity(0.3), in: .circle)
                .accessibilityLabel("合集")
            }
            // AI 智能推荐入口：仅当用户配了 DeepSeek key 时显示
            if AppSettings.hasDeepSeekAPIKey {
                Button {
                    vm.runAIRecommendNow()
                } label: {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.3), in: .circle)
                }
                .accessibilityLabel("AI 智能推荐")
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
                // 上一首:playlist 模式下可用,否则禁用(单视频播放没有上一首的概念)
                Button { goToPreviousPlaylistItem() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title3)
                        .foregroundStyle(canAdvancePrev ? .white : .white.opacity(0.3))
                }
                .disabled(!canAdvancePrev)

                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                }

                // 下一首:同上
                Button { advancePlaylistIfNeeded() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title3)
                        .foregroundStyle(canAdvanceNext ? .white : .white.opacity(0.3))
                }
                .disabled(!canAdvanceNext)

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
    /// - 已存在条目：更新 progressSeconds + watchedAt + 当前分 P 信息（顺手同步 title/cover/duration）
    /// - 不存在条目：仅在真的看了一会儿（>=3s）才插入
    private func saveProgress() {
        let aid = vm.video.aid
        let progress = Int(vm.currentTime)
        let snapshot = vm.currentPartSnapshot
        let descriptor = FetchDescriptor<PlaybackHistory>(predicate: #Predicate { $0.aid == aid })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.lastModifiedAt = .now
            existing.progressSeconds = progress
            existing.watchedAt = Date()
            existing.title = vm.video.title
            existing.coverURL = vm.video.coverURL
            existing.duration = vm.video.duration
            // 记录最后播放的分 P(0 表示单 P 视频)
            existing.partCid = snapshot.cid
            existing.partPage = snapshot.page
            existing.partTitle = snapshot.title
        } else if progress >= 3 {
            let entry = PlaybackHistory(
                video: vm.video,
                progressSeconds: progress,
                partCid: snapshot.cid,
                partPage: snapshot.page,
                partTitle: snapshot.title
            )
            modelContext.insert(entry)
        } else {
            return
        }
        modelContext.saveAndKickSync()
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
        modelContext.saveAndKickSync()
    }

    // MARK: - 播放列表自动连播 / 上一首下一首

    /// 是否可以"上一首"(优先级: 分P → 手动 playlist → 合集)
    private var canAdvancePrev: Bool {
        if vm.currentPartIndex > 0 { return true }
        if !playlist.isEmpty {
            return playlistIndex > 0
        }
        if let s = vm.seasonPlaylist {
            return vm.seasonCurrentIndex > 0
        }
        return false
    }

    /// 是否可以"下一首":同 canAdvancePrev 的语义
    private var canAdvanceNext: Bool {
        if let parts = vm.parts, vm.currentPartIndex < parts.count - 1 { return true }
        if !playlist.isEmpty {
            return playlistIndex < playlist.count - 1
        }
        if let s = vm.seasonPlaylist {
            return vm.seasonCurrentIndex < s.count - 1
        }
        return false
    }

    private func advancePlaylistIfNeeded(vm: VideoPlayerViewModel? = nil) {
        let targetVM = vm ?? self.vm
        // 1. 分P(最高优先级, 同一个 BV 号下的段落)
        if let parts = targetVM.parts, targetVM.currentPartIndex < parts.count - 1 {
            let next = targetVM.currentPartIndex + 1
            AppLogger.info("Player: advancing to part[\(next)]")
            targetVM.switchToPart(at: next)
            return
        }
        // 2. 手动 playlist
        if !playlist.isEmpty {
            let nextIndex = playlistIndex + 1
            guard nextIndex < playlist.count else {
                AppLogger.info("Player: manual playlist ended at index \(playlistIndex)/\(playlist.count - 1)")
                return
            }
            AppLogger.info("Player: advancing to playlist[\(nextIndex)]")
            playlistIndex = nextIndex
            targetVM.switchVideo(playlist[nextIndex])
            return
        }
        // 3. 合集
        if let s = targetVM.seasonPlaylist {
            let nextIndex = targetVM.seasonCurrentIndex + 1
            guard nextIndex < s.count else {
                AppLogger.info("Player: season ended at index \(targetVM.seasonCurrentIndex)/\(s.count - 1)")
                return
            }
            AppLogger.info("Player: advancing to season[\(nextIndex)]")
            targetVM.seasonCurrentIndex = nextIndex
            targetVM.switchVideo(s[nextIndex])
        }
    }

    private func goToPreviousPlaylistItem() {
        // 1. 分P(最高优先级)
        if vm.currentPartIndex > 0 {
            let prevIndex = vm.currentPartIndex - 1
            AppLogger.info("Player: going to part[\(prevIndex)]")
            vm.switchToPart(at: prevIndex)
            return
        }
        // 2. 手动 playlist
        if !playlist.isEmpty, playlistIndex > 0 {
            let prevIndex = playlistIndex - 1
            AppLogger.info("Player: going to playlist[\(prevIndex)]")
            playlistIndex = prevIndex
            vm.switchVideo(playlist[prevIndex])
            return
        }
        // 3. 退回合集
        if let s = vm.seasonPlaylist, vm.seasonCurrentIndex > 0 {
            let prevIndex = vm.seasonCurrentIndex - 1
            AppLogger.info("Player: season going to index \(prevIndex)")
            vm.seasonCurrentIndex = prevIndex
            vm.switchVideo(s[prevIndex])
        }
    }

    /// 视频结束后的统一处理(四级 fallback)
    /// 1. 分P 有下一个 → 自动切(同一个 BV 号下的下一个段落, 最常见)
    /// 2. 手动 playlist 有下一个 → 自动切
    /// 3. 合集有下一个 → 自动切(路径 1)
    /// 4. 有预计算好的推荐 → 弹「推荐视频」页(路径 2)
    /// 5. 都没有 → 停
    private func handleVideoEnd(vm: VideoPlayerViewModel) {
        // 1. 分P
        if let parts = vm.parts, vm.currentPartIndex < parts.count - 1 {
            let next = vm.currentPartIndex + 1
            AppLogger.info("Player: end → part[\(next)]")
            vm.switchToPart(at: next)
            return
        }
        // 2. 手动 playlist
        if !playlist.isEmpty {
            let next = playlistIndex + 1
            if next < playlist.count {
                AppLogger.info("Player: end → manual playlist[\(next)]")
                playlistIndex = next
                vm.switchVideo(playlist[next])
                return
            }
        }
        // 3. 合集
        if let s = vm.seasonPlaylist {
            let next = vm.seasonCurrentIndex + 1
            if next < s.count {
                AppLogger.info("Player: end → season[\(next)]")
                vm.seasonCurrentIndex = next
                vm.switchVideo(s[next])
                return
            }
        }
        // 4. 推荐页
        if let recs = vm.pendingRecommendations, !recs.isEmpty {
            AppLogger.info("Player: end → showing recommendation page (\(recs.count) videos)")
            showRecommendationPage = true
            return
        }
        // 4. 停
        AppLogger.info("Player: end → no next, stopped")
    }

    // MARK: - 控制中心 / 锁定屏 widget

    /// 把当前播放快照推到 MPNowPlayingInfoCenter。rateOverride 用于切歌后立刻用正确的 rate。
    private func pushNowPlayingMetadata(rateOverride: Double? = nil) {
        let rate = rateOverride ?? (vm.isPlaying ? 1.0 : 0.0)
        let elapsed = vm.currentTime.isFinite ? vm.currentTime : 0
        let duration = vm.duration.isFinite && vm.duration > 0 ? vm.duration : elapsed
        NowPlayingController.shared.update(
            title: vm.video.title,
            artist: vm.video.authorName,
            artworkURL: vm.video.coverURL,
            duration: duration,
            elapsed: elapsed,
            rate: rate
        )
    }

    /// 5s 一次的周期任务里调一次,只刷 elapsed(其它字段不重写,避免覆盖异步加载回来的封面)
    private func refreshNowPlayingElapsed() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = vm.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = vm.isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - 分P 视频列表 sheet

/// 顶部「分P」按钮点开：列出该 BV 号下的所有分P, 点击跳到指定分P
private struct PartListSheet: View {
    let videoTitle: String
    let parts: [BilibiliVideoPart]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                            Button {
                                onSelect(idx)
                            } label: {
                                HStack(spacing: 10) {
                                    Text("\(part.page)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(part.part).font(.subheadline)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        Text(formatPartDuration(part.duration))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if idx == currentIndex {
                                        Image(systemName: "play.fill").foregroundStyle(.tint)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .id(idx)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(videoTitle).font(.subheadline.bold()).lineLimit(2)
                            Text("共 \(parts.count) 个分P").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    // 打开时滚动到当前播放的分P
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation { proxy.scrollTo(currentIndex, anchor: .center) }
                    }
                }
            }
            .navigationTitle("分P")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 把秒数格式化成 "MM:SS" 或 "HH:MM:SS"(给分P 时长用, 通常不会超过 1 小时)
    private func formatPartDuration(_ seconds: Int) -> String {
        if seconds <= 0 { return "--:--" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}

// MARK: - 合集视频列表 sheet

/// 路径 1：当前视频在合集里时, 顶部按钮点开, 看到合集所有视频
private struct SeasonListSheet: View {
    let meta: VideoPlayerViewModel.SeasonMeta?
    let videos: [VideoItem]
    let currentAid: Int
    let onSelect: (VideoItem) -> Void
    let modelContext: ModelContext
    @Environment(\.dismiss) private var dismiss
    let onBackfillComplete: (Int) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if videos.isEmpty {
                    ContentUnavailableView(
                        "合集数据为空",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("本地库还没记录这个合集的视频。\n去「正在播放」的同合集其他视频里点开一下, 库就会自动补齐。")
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                // 头部: 合集标题 + 封面 + 总数
                                if let m = meta {
                                    headerSection(m: m)
                                        .id("top")
                                }
                                // 视频列表
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(videos.enumerated()), id: \.element.id) { idx, v in
                                        seasonRow(idx: idx, v: v)
                                            .id(v.aid)  // 给 ScrollViewReader 用
                                            .background(
                                                v.aid == currentAid
                                                    ? Color.accentColor.opacity(0.12)
                                                    : Color.clear
                                            )
                                        Divider()
                                    }
                                }
                                // 提示: 本地数据可能不完整
                                VStack(spacing: 4) {
                                    Text("列表只显示本地已有合集 ID 的视频").font(.caption2).foregroundStyle(.tertiary)
                                    Text("点开更多合集视频可自动补全").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(.top, 16)
                                .padding(.bottom, 32)
                            }
                        }
                        .onAppear {
                            // 打开时滚动到当前播放的视频
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation { proxy.scrollTo(currentAid, anchor: .center) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("合集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onChange(of: backfillState.isRunning) {
            if !backfillState.isRunning, backfillState.lastMatchedCount > 0 {
                onBackfillComplete(backfillState.lastMatchedCount)
            }
        }
    }

    @ObservedObject private var backfillState = SeasonBackfillState.shared
    /// 触发的 mid + seasonID(在 init 时由调用方传入)
    let backfillMid: String
    let backfillSeasonID: Int

    private func headerSection(m: VideoPlayerViewModel.SeasonMeta) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let cover = m.cover, let url = URL(string: cover) {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { Color.gray.opacity(0.2) }
                    .frame(width: 60, height: 60)
                    .clipShape(.rect(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.name).font(.headline).lineLimit(2)
                    Text("本地共 \(m.total) 个 · 按发布时间排序").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            // 手动补全按钮(已知合集比 B 站合集短时, 用户可点这个拉完整)
            HStack {
                Button {
                    backfillState.startBackfillOne(
                        mid: backfillMid, seasonID: backfillSeasonID, context: modelContext
                    )
                } label: {
                    if backfillState.isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("补全中...").font(.caption)
                        }
                    } else {
                        Label("补全本合集所有视频", systemImage: "arrow.down.circle")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(backfillState.isRunning)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.gray.opacity(0.08))
    }

    private func seasonRow(idx: Int, v: VideoItem) -> some View {
        Button {
            onSelect(v)
        } label: {
            HStack(spacing: 10) {
                Text("\(idx + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
                AsyncImage(url: URL(string: v.coverURL)) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 110, height: 65)
                .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(v.title).font(.subheadline).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if v.aid == currentAid {
                        Text("正在播放").font(.caption2).foregroundStyle(.tint)
                    }
                }
                Spacer(minLength: 0)
                if v.aid == currentAid {
                    Image(systemName: "play.fill").foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 「播完后推荐」视频页 sheet

/// 路径 2：当前视频没有合集, 或者合集拉取失败, 播完后弹出这个页
/// - 展示 pendingRecommendations（前 60s 算好的）
/// - 用户点一个就切歌
private struct RecommendationSheet: View {
    let currentVideo: VideoItem
    let recommendations: [VideoItem]
    let onSelect: (VideoItem) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if recommendations.isEmpty {
                    // 空态: 根据不同原因给不同提示
                    VStack(spacing: 12) {
                        Image(systemName: emptyStateIcon).font(.system(size: 50)).foregroundStyle(.secondary)
                        Text(emptyStateTitle).font(.headline)
                        Text(emptyStateDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.top, 80)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        // 头部
                        VStack(alignment: .leading, spacing: 4) {
                            Text("刚看完").font(.caption).foregroundStyle(.secondary)
                            Text(currentVideo.title).font(.subheadline.bold()).lineLimit(1)
                        }
                        .padding(.horizontal, 16)

                        // 推荐网格
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(recommendations.enumerated()), id: \.element.id) { _, v in
                                Button {
                                    onSelect(v)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        AsyncImage(url: URL(string: v.coverURL)) { img in
                                            img.resizable().scaledToFill()
                                        } placeholder: { Color.gray.opacity(0.2) }
                                        .frame(maxWidth: .infinity)
                                        .aspectRatio(16.0/9.0, contentMode: .fill)
                                        .clipShape(.rect(cornerRadius: 6))
                                        Text(v.title)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                            .foregroundStyle(.primary)
                                        Text(v.authorName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 12)
                }
            }
            .navigationTitle("推荐下一个")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
    /// 空态文案：根据当前 settings / 库状态挑一个最贴切的解释
    private var emptyStateIcon: String {
        if !AppSettings.hasEmbeddingAPIKey { return "key.slash" }
        return "sparkles"
    }
    private var emptyStateTitle: String {
        if !AppSettings.hasEmbeddingAPIKey { return "未配置 Embedding API key" }
        if AppSettings.localRecommendMode == .deepseek && !AppSettings.hasDeepSeekAPIKey {
            return "推荐模式选了 DeepSeek 但没配 key"
        }
        return "暂无推荐"
    }
    private var emptyStateDetail: String {
        if !AppSettings.hasEmbeddingAPIKey {
            return "本地向量库为空, 又没配 embedding API。\n去「设置 → Embedding」填一个 key, 然后点「重新构建向量库」。"
        }
        return "本地向量库可能还在建库中(几千个视频要几分钟)。\n几分钟后回来重看一次这个视频就能用上推荐了。\n\n也可以在「设置 → Embedding」点「重新构建」手动触发。"
    }
