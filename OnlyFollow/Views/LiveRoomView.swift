import SwiftUI
import SwiftData
import AVKit

/// 全屏直播播放页
/// - UI 风格与 VideoPlayerView 对齐：顶栏 chevron.down 关闭 + 标题 + UP主
/// - 中部：HLS / FLV 视频流（AVPlayer 直接播；后续可换 IJKPlayer 走 FLV）
/// - 弹幕：通过 LiveDanmakuHost 包装，自动桥接 B 站 / 抖音弹幕服务
/// - 历史：onAppear 写一条 LiveHistory（与 PlaybackHistory 同样的同步语义）
/// - 关闭：chevron.down 按钮 + danmakuHost.disconnect + 暂停 player
/// - 控件：单击切换显隐，3 秒自动隐藏；包含弹幕开关、播放/暂停、全屏、定时关闭
/// - 锁定：右侧悬浮锁按钮（与视频侧一致）；锁定后只剩锁按钮，屏幕点击无效；再点锁按钮 → 控件全套浮现
struct LiveRoomView: View {
    let room: LiveRoom
    let modelContext: ModelContext

    /// 平台无关的弹幕服务包装（B 站或抖音）
    /// - 内部 service 是延迟绑定的：load() 里根据 platform 取签名/token 后才 attach
    @StateObject private var danmakuHost = LiveDanmakuHost()

    @State private var streamURL: URL?
    @State private var loadError: String?
    /// 任务句柄：onDisappear 时取消，防止 view 消失后还有续命工作
    @State private var loadTask: Task<Void, Never>?
    @State private var player: AVPlayer?
    @State private var playerObserver: LiveRoomPlayerObserver?
    @State private var isPlaying: Bool = true
    /// 控件显隐（顶栏 + 底栏）：单击切换；显示后 3s 自动隐藏
    @State private var showControls: Bool = true
    @State private var controlsHideTask: Task<Void, Never>?
    /// 全屏（横屏 + 隐藏状态栏）。注意"全屏"和视频侧语义一致
    @State private var isFullscreen: Bool = false
    /// 弹幕叠加层显隐
    @State private var danmakuEnabled: Bool = true
    /// 锁定：true 时只有锁按钮可见，屏幕点击无效
    @State private var isLocked: Bool = false
    /// 定时关闭剩余秒数；nil = 未启用
    @State private var sleepRemainingSeconds: Int?
    @State private var sleepTimerTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(room: LiveRoom, modelContext: ModelContext) {
        self.room = room
        self.modelContext = modelContext
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                AVPlayerLayerView(player: player)
                    .ignoresSafeArea()
            }

            if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundStyle(.white)
                    Text(loadError)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            } else if streamURL == nil {
                VStack(spacing: 16) {
                    ProgressView().tint(.white)
                    Text("连接直播间...")
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            // 弹幕叠加层（受 danmakuEnabled 控制）
            // 通过 danmakuHost 拿底层 messages（自动桥接 B/D）
            if danmakuEnabled {
                VStack {
                    Spacer()
                    DanmakuOverlayView(messages: danmakuHost.messages)
                }
                .allowsHitTesting(false)
            }

            // 控件层（顶栏 + 底栏 + 渐变背景）。锁定时整个隐藏，只剩锁按钮
            if showControls && !isLocked {
                controlsOverlay
                    .transition(.opacity)
            }

            // 锁按钮：始终在右侧中部。锁定时是唯一可见的 UI 元素
            // 关键：放在 controlsOverlay 之外，这样它不会被 showControls gate 掉
            lockButton
        }
        .preferredColorScheme(.dark)
        // 视频侧的状态栏策略：全屏时隐藏，否则正常
        .statusBarHidden(isFullscreen)
        // 单击切换控件显隐。锁定时不响应
        .onTapGesture {
            guard !isLocked else { return }
            tapSurface()
        }
        .task {
            loadTask = Task { await load() }
            await loadTask?.value
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            controlsHideTask?.cancel()
            sleepTimerTask?.cancel()
            // 通过 host disconnect，自动转发到底层 B/D 服务
            Task { await danmakuHost.disconnect() }
            player?.pause()
            // 退出时如果还在横屏就拉回竖屏
            if isFullscreen { AppOrientationHelper.setOrientation(.portrait) }
        }
    }

    // MARK: - 控件层

    private var controlsOverlay: some View {
        VStack {
            topBar
            Spacer()
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
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.3), in: .circle)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(room.title).font(.subheadline.bold()).foregroundStyle(.white).lineLimit(1)
                Text(room.authorName).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            HStack(spacing: 4) {
                // danmakuHost 自动桥接 B/D 服务的 isConnected
                if danmakuHost.isConnected {
                    Circle().fill(.green).frame(width: 8, height: 8)
                }
                Image(systemName: "eye").font(.caption)
                Text("\(room.viewerCount)")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.3), in: .capsule)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 24) {
            // 弹幕开关（与视频侧 toggleDanmaku 一致）
            Button { toggleDanmaku() } label: {
                Image(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                    .font(.title3)
                    .foregroundStyle(danmakuEnabled ? .yellow : .white)
            }

            // 播放 / 暂停
            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }

            Spacer()

            // 定时关闭
            sleepTimerButton

            // 全屏（横屏 + 隐藏状态栏；和视频侧 isFullscreen 语义一致）
            Button { toggleFullscreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
    }

    /// 锁定按钮：屏幕右侧中部
    /// - 锁定时（isLocked == true）显示 lock.fill；解锁时显示 lock.open.fill
    /// - 永远在 controlsOverlay 之外，所以锁定时它是唯一可见的 UI
    /// - 点击：锁定 → 隐藏所有控件；解锁 → 控件全套浮现
    private var lockButton: some View {
        VStack {
            Spacer()
            Button {
                toggleLock()
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

    /// 倒计时显示用的按钮：未启动是月亮图标，启动后是"剩余 MM:SS"胶囊
    /// - 视觉上跟视频侧 sleepTimerButton 一致（仅居中位置和上下文不同）
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

    // MARK: - 控件交互

    /// 切换播放/暂停；同步 isPlaying 状态
    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        scheduleControlsHide()
    }

    /// 单击切换控件显隐；显示后 3s 自动隐藏
    /// - 全屏时也能调用（之前是 `&& !isFullscreen` gate，但用户反馈"点了全屏就再点不出控件"）
    /// - 现在不再 gate，全屏下单击会先把控件唤出来，用户可以再点全屏按钮退出
    private func tapSurface() {
        showControls.toggle()
        if showControls {
            scheduleControlsHide()
        } else {
            controlsHideTask?.cancel()
            controlsHideTask = nil
        }
    }

    /// 切换弹幕显隐
    private func toggleDanmaku() {
        danmakuEnabled.toggle()
        scheduleControlsHide()
    }

    /// 切换全屏（横屏 + 隐藏状态栏）
    /// - 进入全屏时不要立刻把控件也藏起来，让用户能看到底栏的全屏按钮自己选择退出
    private func toggleFullscreen() {
        isFullscreen.toggle()
        AppOrientationHelper.setOrientation(isFullscreen ? .landscape : .portrait)
        scheduleControlsHide()
    }

    /// 切换锁定
    /// - 锁定 → 控件全消失，只剩锁按钮
    /// - 解锁 → 控件全套浮现（不要重新 hide，让用户继续操作；3s 后照常自动隐藏）
    private func toggleLock() {
        isLocked.toggle()
        if isLocked {
            // 锁定：把控件和定时隐藏都关掉，确保屏幕干净
            showControls = false
            controlsHideTask?.cancel()
            controlsHideTask = nil
        } else {
            // 解锁：把控件全套浮回来
            showControls = true
            scheduleControlsHide()
        }
    }

    /// 控件显示后 3s 自动隐藏
    private func scheduleControlsHide() {
        // 锁定时不要自动隐藏（虽然 controlsOverlay 在锁定时已经隐藏）
        guard !isLocked else { return }
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            showControls = false
        }
    }

    // MARK: - 定时关闭

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
            // 到点暂停
            player?.pause()
            isPlaying = false
            sleepRemainingSeconds = nil
            AppLogger.info("LiveRoom: sleep timer expired, paused")
            // 重新弹出控件让用户知道
            showControls = true
            scheduleControlsHide()
        }
        scheduleControlsHide()
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepRemainingSeconds = nil
        scheduleControlsHide()
    }

    private func formatCountdown(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - 加载流程

    /// 加载顺序（平台分发）：
    /// 1. 写一条 LiveHistory
    /// 2. fetch live stream URL（平台分发）
    /// 3. 拿到 stream URL 后用 AVPlayer 播
    /// 4. fetch danmu info → 把具体 service attach 到 host，然后 host.connect()
    private func load() async {
        AppLogger.info("LiveRoom: 进入直播间 platform=\(room.platform) roomID=\(room.roomID) title=\(room.title) author=\(room.authorName)")
        recordHistory()

        switch room.platform {
        case "bilibili":
            await loadBilibili()
        case "douyin":
            await loadDouyin()
        default:
            loadError = "不支持的平台: \(room.platform)"
        }

        // 加载完所有控件，开启首次自动隐藏倒计时
        scheduleControlsHide()
    }

    // MARK: - B 站加载

    /// B 站拉流 + 弹幕
    /// - 弹幕需要先 fetchDanmuInfo 拿 token/host/wssPort，然后再 attach host
    private func loadBilibili() async {
        let api = BilibiliAPIService.shared

        // 1) 直播流
        do {
            let (urlString, qn) = try await api.fetchLiveStreamURL(roomID: Int(room.roomID) ?? 0)
            AppLogger.info("LiveRoom: 拿到 B 站直播流 qn=\(qn), 开始建 AVPlayer")
            guard let url = URL(string: urlString) else {
                loadError = "直播流地址无效"
                return
            }
            streamURL = url
            let p = AVPlayer(url: url)
            p.allowsExternalPlayback = true
            // 关键：让直播流也能继续在后台播放（与视频一致）
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            p.play()
            player = p
        } catch {
            let msg = "加载 B 站直播流失败：\(error.localizedDescription)"
            AppLogger.error("LiveRoom: \(msg) roomID=\(room.roomID)")
            loadError = msg
            return
        }

        // 2) B 站弹幕：fetch danmu info → 构造 service → attach 到 host
        do {
            let info = try await api.fetchDanmuInfo(roomID: Int(room.roomID) ?? 0)
            guard let hostInfo = info.data.hostList.first else {
                AppLogger.error("LiveRoom: danmuInfo 没有任何 host，roomID=\(room.roomID)")
                return
            }
            let wssHost = hostInfo.host
            let wssPort = hostInfo.wssPort > 0 ? hostInfo.wssPort : 443
            let token = info.data.token
            let buvid = BilibiliSessionManager.shared.buvid3
            AppLogger.info("LiveRoom: B 站弹幕 host=\(wssHost) wssPort=\(wssPort) tokenLen=\(token.count) buvid3Len=\(buvid.count)")
            let biliService = BilibiliDanmakuService(
                roomID: Int(room.roomID) ?? 0,
                token: token,
                host: wssHost,
                wssPort: wssPort,
                buvid: buvid
            )
            danmakuHost.attach(bili: biliService)
            await danmakuHost.connect()
        } catch {
            // 弹幕连不上不影响直播播放，只打日志
            AppLogger.error("LiveRoom: B 站弹幕初始化失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 抖音加载

    /// 从抖音直播流中选择 AVPlayer 能播的 URL
    /// - macOS AVPlayer 原生支持 HLS(m3u8),**不支持 FLV**
    /// - 抖音同时返回 flv_pull_url 和 hls_pull_url,优先 HLS
    /// - 如果只有 FLV 也没有别的,继续用 FLV 让 AVPlayer 报真实错误,而不是悄悄换
    private func pickPlayableStreamURL(from info: DouyinUserInfo.LiveRoomInfo) -> String? {
        if let hls = info.hlsURL, !hls.isEmpty { return hls }
        if let flv = info.flvURL, !flv.isEmpty { return flv }
        return info.streamURL
    }

    /// 抖音拉流 + 弹幕
    /// - 1) 优先用 sec_uid 调 user profile 拿 stream URL (绕过 enter 接口, enter 接口对部分房间返回 4001038)
    /// - 2) fallback: 调 DouyinAPIService.fetchLiveRoom (webcast/room/web/enter/)
    /// - 3) DouyinDanmakuService 构造好后 attach 到 host，host.connect()
    private func loadDouyin() async {
        let api = DouyinAPIService.shared
        var streamURLString = ""
        // HLS 优先 (AVPlayer 原生支持)，FLV 作为 fallback (后续可接 IJKPlayer)
        var streamFormat = ""

        // 1a) 优先: user profile API 拿 stream URL (实测更稳定, enter 接口对某些房间返回 4001038)
        if !room.authorUID.isEmpty {
            do {
                let user = try await api.fetchUserInfo(secUid: room.authorUID)
                if let info = user.liveRoomInfo, let url = pickPlayableStreamURL(from: info), !url.isEmpty {
                    streamURLString = url
                    streamFormat = "user_profile"
                    AppLogger.info("LiveRoom: user profile 拿到抖音直播流 url=\(url.prefix(80))...")
                } else if let info = user.liveRoomInfo, info.isLiving {
                    loadError = "该抖音主播当前未开播"
                    return
                }
            } catch {
                AppLogger.warning("LiveRoom: user profile 拿流失败, 回退 enter 接口: \(error.localizedDescription)")
            }
        }

        // 1b) fallback: enter 接口
        if streamURLString.isEmpty {
            do {
                let resp = try await api.fetchLiveRoom(webcastId: room.roomID, roomIdStr: room.roomID)
                let info = DouyinLiveRoomInfo.from(resp)
                if info.isLiving {
                    streamURLString = info.hlsURL ?? info.flvURL ?? ""
                    streamFormat = "enter_api"
                } else {
                    loadError = "该抖音主播当前未开播"
                    return
                }
            } catch {
                let msg = "加载抖音直播流失败：\(error.localizedDescription)"
                AppLogger.error("LiveRoom: \(msg) roomID=\(room.roomID)")
                loadError = msg
                return
            }
        }

        guard !streamURLString.isEmpty, let url = URL(string: streamURLString) else {
            loadError = "抖音直播流地址无效 (来源: \(streamFormat))"
            return
        }
        AppLogger.info("LiveRoom: 拿到抖音直播流 (来源=\(streamFormat)) url.scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil") path=\(url.path.prefix(40))")
        AppLogger.info("LiveRoom: 完整 URL (前 200) = \(url.absoluteString.prefix(200))")
        streamURL = url

        // 调试: 检查 URL 是否可播放 (FLV 格式 macOS AVPlayer 默认不支持, 这里提前发现)
        let asset = AVURLAsset(url: url)
        AppLogger.info("LiveRoom: asset created, duration=async, isPlayable=待查")

        let p = AVPlayer(url: url)
        p.allowsExternalPlayback = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        // 调试: KVO 监听 currentItem.status 和 AVPlayerItem.error, 拿到真实错误原因
        let observer = LiveRoomPlayerObserver(player: p)
        observer.start()
        playerObserver = observer

        p.play()
        player = p

        // 调试: 异步查 asset.isPlayable + 是否有视频/音轨, 看 AVPlayer 是否真的能解 FLV
        Task { @MainActor in
            do {
                let isPlayable = try await asset.load(.isPlayable)
                AppLogger.info("LiveRoom: asset.isPlayable=\(isPlayable)")
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                AppLogger.info("LiveRoom: asset tracks video=\(videoTracks.count) audio=\(audioTracks.count)")
                for (i, track) in videoTracks.enumerated() {
                    let descs = try await track.load(.formatDescriptions)
                    if let desc = descs.first {
                        let formatDesc = desc as CMFormatDescription
                        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
                        AppLogger.info("LiveRoom: video track \(i) codec=0x\(String(mediaSubType, radix: 16, uppercase: true))")
                    }
                }
            } catch {
                AppLogger.error("LiveRoom: asset load failed: \(error.localizedDescription)")
            }
        }

        // 2) 抖音弹幕：构造 DouyinDanmakuService → attach → connect
        // 注意：房间在开播状态下 room.roomID 已经是真实 room_id（webcast_id 与 room_id 同一个值在 douyin 当前的 enter 接口中）
        let douyinService = DouyinDanmakuService(
            roomId: room.roomID,
            ownerSecUid: room.authorUID.isEmpty ? nil : room.authorUID
        )
        danmakuHost.attach(douyin: douyinService)
        await danmakuHost.connect()
    }

    /// 写 LiveHistory：已存在则更新 watchedAt + 元数据（防止 UP 主改名 / 换头像后历史列表还停留在旧值）
    private func recordHistory() {
        let roomID = Int(room.roomID) ?? 0
        let descriptor = FetchDescriptor<LiveHistory>(predicate: #Predicate { $0.roomID == roomID })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.lastModifiedAt = .now
            existing.watchedAt = .now
            existing.title = room.title
            existing.coverURL = room.coverURL
            existing.authorUID = room.authorUID
            existing.authorName = room.authorName
            existing.authorAvatar = room.authorAvatar
            existing.platform = room.platform
        } else {
            let entry = LiveHistory(
                roomID: roomID,
                title: room.title,
                coverURL: room.coverURL,
                authorUID: room.authorUID,
                authorName: room.authorName,
                authorAvatar: room.authorAvatar,
                platform: room.platform,
                watchedAt: .now
            )
            modelContext.insert(entry)
        }
        modelContext.saveAndKickSync()
    }
}

/// 调试用: KVO 监听 AVPlayer / AVPlayerItem 状态变化, 把真实错误暴露到日志
@MainActor
final class LiveRoomPlayerObserver {
    private let player: AVPlayer
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []

    init(player: AVPlayer) {
        self.player = player
    }

    func start() {
        // 监听 currentItem 变化
        let itemObs = player.observe(\.currentItem, options: [.new, .old]) { [weak self] player, _ in
            guard let item = player.currentItem else { return }
            AppLogger.info("LiveRoom: AVPlayer currentItem 变化")
            self?.attachItemObservers(item)
        }
        observations.append(itemObs)

        // 监听 player.timeControlStatus
        let ctrlObs = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            AppLogger.info("LiveRoom: timeControlStatus = \(player.timeControlStatus.rawValue) (0=paused, 1=playing, 2=waitingToPlay)")
        }
        observations.append(ctrlObs)

        // 监听 player.status
        let statusObs = player.observe(\.status, options: [.new]) { player, _ in
            AppLogger.info("LiveRoom: AVPlayer.status = \(player.status.rawValue) (unknown=0, readyToPlay=1, failed=-1)")
        }
        observations.append(statusObs)

        // 监听 reasonForWaitingToPlay
        let reasonObs = player.observe(\.reasonForWaitingToPlay, options: [.new]) { player, _ in
            AppLogger.info("LiveRoom: reasonForWaitingToPlay = \(String(describing: player.reasonForWaitingToPlay))")
        }
        observations.append(reasonObs)

        if let item = player.currentItem {
            attachItemObservers(item)
        }
    }

    private func attachItemObservers(_ item: AVPlayerItem) {
        itemObservations.removeAll()
        let statusObs = item.observe(\.status, options: [.new]) { item, _ in
            AppLogger.info("LiveRoom: AVPlayerItem.status = \(item.status.rawValue) (unknown=0, readyToPlay=1, failed=-1)")
            if item.status == .failed, let err = item.error {
                let nsErr = err as NSError
                AppLogger.error("LiveRoom: AVPlayerItem.error = \(err) [domain=\(nsErr.domain) code=\(nsErr.code)]")
                AppLogger.error("LiveRoom: AVPlayerItem.error.userInfo = \((err as NSError).userInfo)")
            }
        }
        itemObservations.append(statusObs)

        let errorObs = item.observe(\.error, options: [.new]) { item, _ in
            if let err = item.error {
                let nsErr = err as NSError
                AppLogger.error("LiveRoom: AVPlayerItem.error 变化 = \(err) [domain=\(nsErr.domain) code=\(nsErr.code)]")
                AppLogger.error("LiveRoom: AVPlayerItem.error.userInfo = \((err as NSError).userInfo)")
            }
        }
        itemObservations.append(errorObs)

        let loadedObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { item, _ in
            AppLogger.info("LiveRoom: isPlaybackLikelyToKeepUp = \(item.isPlaybackLikelyToKeepUp)")
        }
        itemObservations.append(loadedObs)
    }

    deinit {
        observations.forEach { $0.invalidate() }
        itemObservations.forEach { $0.invalidate() }
    }
}
