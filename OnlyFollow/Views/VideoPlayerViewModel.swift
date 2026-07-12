import Foundation
import SwiftUI
import AVKit
import AVFAudio
import Combine
import SwiftData

/// 视频播放器视图模型
/// 职责：拉播放 URL → 加载弹幕 → 维护播放状态 → 暴露给 UI 绑定
@MainActor
final class VideoPlayerViewModel: ObservableObject {
    var video: VideoItem
    /// 进入播放页时由 View 从 PlaybackHistory 读出的续播位置。
    /// load() 完成后会自动 seek 到这里（前提是 >5s 且没看完）。
    var initialResumeSeconds: Double?
    /// 进入播放页时由 View 从 PlaybackHistory 读出的"上次看的分 P"的 cid
    /// load() 拉到 parts[] 后,如果能找到这个 cid 对应的 part,会先切过去再 seek
    var resumePartCid: Int = 0

    @Published var avPlayer: AVPlayer?
    /// KVO 观察的 playerItem(tearDown 时 removeObserver 用)
    private var currentItemForKVO: AVPlayerItem?
    /// Combine cancellables(AVPlayerItem.status publisher 等)
    private var cancellables = Set<AnyCancellable>()
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    /// currentTime 上一次被 AVPlayer observer 写入的 wall time
    /// 弹幕渲染用它做插值，避免 AVPlayer 0.5s 采样导致 PPT 跳
    @Published private(set) var currentTimeUpdatedAt: Date = Date()
    /// 切到后台的时刻（handleScenePhase 用），切回前台时重置 currentTimeUpdatedAt
    private var lastBackgroundAt: Date?
    @Published var duration: Double = 0
    @Published var loadError: String?
    @Published var showControls = true
    @Published var isFullscreen = false
    @Published var danmakuEnabled = true
    @Published var quality: Int = 0
    @Published var isFavorited: Bool = false

    /// 全部弹幕（按 videoTime 升序）
    @Published private(set) var allDanmaku: [VideoDanmaku] = []

    // MARK: - 分 P 相关

    /// 视频的所有分 P(`data.pages[]`)。单 P 视频长度为 1; nil 表示还没拿到(还没 fetchVideoDetail).
    /// - 与合集(UGC season)概念不同: 合集是 UP 主把多个视频归类到一起; 分 P 是同一个 BV 号下的多个段落
    /// - 字段从 fetchVideoDetail 拿, 无需额外请求 pagelist 接口
    @Published private(set) var parts: [BilibiliVideoPart]?
    /// 当前播放的分 P 在 parts 里的索引(0-based)
    private(set) var currentPartIndex: Int = 0
    /// 当前播放的分 P 的 cid(供 fetchPlayURL + 弹幕加载用)
    var currentCid: Int {
        if let parts = parts, !parts.isEmpty, currentPartIndex < parts.count {
            return parts[currentPartIndex].cid
        }
        return video.cid
    }
    /// 当前播放的分 P 对象(给 UI 绑定用; 单 P 视频为 nil)
    var currentPart: BilibiliVideoPart? {
        if let parts = parts, !parts.isEmpty, currentPartIndex < parts.count, parts.count > 1 {
            return parts[currentPartIndex]
        }
        return nil
    }
    /// 该视频是否是多 P 视频(决定是否显示分P按钮 / 是否启用分P自动连播)
    var hasMultipleParts: Bool { (parts?.count ?? 0) > 1 }

    /// 给 PlaybackHistory 用的快照：当前分 P 的 cid / 页码 / 标题
    /// - progressSeconds 由 vm 自己管（外部从 currentTime 拿）
    /// - 直播 / 抖音 / 单 P 视频：cid=0, page=0, title=""
    var currentPartSnapshot: (cid: Int, page: Int, title: String) {
        guard let parts = parts, !parts.isEmpty,
              currentPartIndex < parts.count else {
            return (0, 0, "")
        }
        let p = parts[currentPartIndex]
        return (p.cid, p.page, p.part)
    }

    // MARK: - 播下一个 相关

    /// 合集(B 站 UGC season)视频列表;成功拉到后 View 可以直接当 playlist 用
    /// - 拉取失败 / 当前视频不在合集里：保持 nil
    @Published private(set) var seasonPlaylist: [VideoItem]?
    /// 合集元信息(标题/封面/总集数)
    @Published private(set) var seasonMeta: SeasonMeta?
    /// 合集视频里当前播放的 index(VM 自己维护)
    var seasonCurrentIndex: Int = 0
    /// 合集拉取中(顶部按钮旋转用)
    @Published private(set) var isFetchingSeason: Bool = false

    /// 预计算好的「播完后推荐」视频(本地向量 / DeepSeek)
    /// - 在视频还剩 60s 时由 VM 自动触发 computePreEndRecommendations 计算
    /// - 播完时如果非空, View 弹推荐视频页
    @Published private(set) var pendingRecommendations: [VideoItem]?
    @Published private(set) var isComputingRecommendations: Bool = false
    /// pre-end 触发器是否已 fire 过（同一视频里只能 fire 一次, 切歌后重置）
    private var preEndTriggerFired: Bool = false
    /// pre-end 触发器跑在后台的 task, 切歌/退出时 cancel
    private var preEndTask: Task<Void, Never>?

    /// 合集元信息(简化版, 避免 View 直接 import BilibiliModels)
    struct SeasonMeta: Equatable {
        let seasonID: Int
        let name: String
        let cover: String?
        let total: Int
    }

    /// ModelContext 由 View 在构造时注入（player 在 main actor,context 必须是同一个 main context）
    var modelContext: ModelContext?

    /// 当前视频正常播放结束回调（用于播放列表自动连播）
    /// 不通过 @Published 计数 + onChange 触发，避免旧 observer 残留导致重复触发
    var onCurrentVideoEnd: (() -> Void)?

    private var timeObserverToken: Any?
    private var endObserverToken: NSObjectProtocol?
    private var hideControlsTask: Task<Void, Never>?
    /// 页面退出（tearDown）标记。设置后 load() 在任何 await 后会自检并提前 return，避免在 view 已经消失的情况下调 player.play()
    private var isCancelled = false

    init(video: VideoItem) {
        self.video = video
    }

    // MARK: - 加载

    func load() async {
        if isCancelled { return }
        do {
            // 0. 设置音频会话
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
                try session.setActive(true, options: [])
            } catch {
                AppLogger.error("Player: audio session setup failed: \(error.localizedDescription)")
            }
            try Task.checkCancellation()
            if isCancelled { return }

            // 1+2. 平台分发：B 站需要 fetchVideoDetail 拿 cid + fetchPlayURL 拿 CDN URL
            //              抖音播放 URL 在 CreatorDetailView 已经缓存到 video.playURL（2 小时有效）
            // - detail 在 B 站路径下会被 fetchVideoDetail 重新赋值为 BilibiliVideoDetail（需要 pages[]）
            // - 抖音路径下保持 VideoItem 不变, 用 playURL 即可
            var detail = video
            var urlStr: String
            switch video.platform {
            case "douyin":
                // 抖音：playURL 已经在 VideoItem.playURL 里（去水印后）
                guard !detail.playURL.isEmpty, let url = URL(string: detail.playURL) else {
                    throw APIError.parseError("抖音播放 URL 缺失（请回 CreatorDetailView 重新加载视频列表）")
                }
                urlStr = url.absoluteString
                quality = 0  // 抖音不分清晰度编号
                AppLogger.info("Player: 抖音播放 url=\(urlStr)  containsPlaywm=\(urlStr.contains("playwm"))  containsPlay=\(urlStr.contains("/play/"))")
            default:
                // B 站：fetchVideoDetail → fetchPlayURL
                // - raw 是 BilibiliVideoDetail（带 pages[] / ugcSeason 等 API 原始字段）
                // - detail 保持 VideoItem; detail.cid 始终是首P的 cid
                if detail.cid == 0 {
                    let raw = try await BilibiliAPIService.shared.fetchVideoDetail(aid: "\(detail.aid)")
                    self.video = raw.toVideoItem()
                    detail = raw.toVideoItem()
                    // 写回 ugcSeasonID 到 VideoRecord（与原逻辑一致）
                    if let ctx = modelContext {
                        let targetAid = detail.aid
                        let desc = FetchDescriptor<VideoRecord>(predicate: #Predicate<VideoRecord> { $0.aid == targetAid })
                        do {
                            if let existing = try ctx.fetch(desc).first {
                                if let sid = raw.ugcSeasonID { existing.ugcSeasonID = sid }
                                if let st = raw.ugcSeason?.title { existing.ugcSeasonTitle = st }
                                existing.lastRefreshedAt = Date()
                                try ctx.save()
                            }
                        } catch {
                            AppLogger.error("Player: 写回 VideoRecord 失败 aid=\(targetAid): \(error.localizedDescription)")
                        }
                    }
                    // 从 raw.pages 拿分 P 列表（同一个 BV 号下的多个段落, 与"合集"是不同概念）
                    // 单 P 视频这里也会返回 1 个元素; 老视频若缺 pages 字段则为 nil, 自动走单 P 流程
                    if let pages = raw.pages, !pages.isEmpty {
                        self.parts = pages
                        // 优先用历史里记的 partCid;找不到(单 P / 老格式)再按 raw.cid 找首 P
                        if resumePartCid > 0, let idx = pages.firstIndex(where: { $0.cid == resumePartCid }) {
                            self.currentPartIndex = idx
                            AppLogger.info("Player: 分 P 列表 aid=\(detail.aid) count=\(pages.count) 按历史 partCid=\(resumePartCid) 切到 index=\(idx)")
                        } else {
                            self.currentPartIndex = pages.firstIndex(where: { $0.cid == raw.cid }) ?? 0
                        }
                        AppLogger.info("Player: 分 P 列表 aid=\(detail.aid) count=\(pages.count) currentIdx=\(self.currentPartIndex)")
                    } else {
                        AppLogger.info("Player: 分 P 列表为空 / 无 pages 字段 aid=\(detail.aid) (按单 P 处理)")
                        self.parts = nil
                        self.currentPartIndex = 0
                    }
                }
                try Task.checkCancellation()
                if isCancelled { return }
                // 用 currentCid 而非 detail.cid: 切歌时 currentPartIndex 可能已变, 这里要拿当前 part 的 cid
                let cidToUse = currentCid
                let (url, q) = try await BilibiliAPIService.shared.fetchVideoPlayURL(aid: "\(detail.aid)", cid: cidToUse)
                urlStr = url
                quality = q
                AppLogger.info("Player: B 站 playURL aid=\(detail.aid) cid=\(cidToUse) quality=\(q) url=\(urlStr.prefix(80))...")
            }

            // 3. 设置 AVPlayer（带 CDN header）

            // 3. 设置 AVPlayer（带 CDN header）
            // - B 站必须带 Referer + UA + Cookie 才能拿到 FLV 分片
            // - 抖音 CDN 是公开的,不需要这些 header;带 Referer 还可能被拒
            guard let url = URL(string: urlStr) else {
                throw APIError.parseError("invalid play url")
            }
            let headers: [String: String]
            switch video.platform {
            case "douyin":
                // 抖音 CDN 现在强制 referer 校验,不带会返 -1102 "You do not have permission"
                // 实测: 只带 Referer 不带 User-Agent 也可以, 但 okhttp UA + 抖音 referer 是最稳的组合
                headers = [
                    "User-Agent": "okhttp/4.9.3",
                    "Referer": "https://www.douyin.com/"
                ]
            default:
                headers = [
                    "User-Agent": BilibiliSessionManager.kDefaultUserAgent,
                    "Referer": "https://www.bilibili.com",
                    "Cookie": BilibiliSessionManager.shared.cookieString
                ]
            }
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            self.avPlayer = player
            // 诊断: 跟踪 AVPlayerItem.status,找"为什么视频不播"
            currentItemForKVO = item
            // 用 Combine publisher 监听 status,避免 KVO 需要 NSObject 基类
            item.publisher(for: \.status)
                .receive(on: RunLoop.main)
                .sink { [weak self] status in
                    guard let self else { return }
                    switch status {
                    case .readyToPlay:
                        AppLogger.info("Player: AVPlayerItem.status = .readyToPlay (视频可播放)")
                    case .failed:
                        AppLogger.error("Player: AVPlayerItem.status = .failed, error=\(String(describing: item.error))")
                    case .unknown:
                        AppLogger.info("Player: AVPlayerItem.status = .unknown (初始/未就绪)")
                    @unknown default:
                        AppLogger.info("Player: AVPlayerItem.status = 未识别")
                    }
                }
                .store(in: &cancellables)
            AppLogger.info("Player: AVPlayerItem created, Combine status subscriber added")

            // player 已经创建出来。这个点之后到 player.play() 之前的任何时间退出，
            // 都必须在这里拦下，不让 player.play() 被调用造成“关掉播放器还能听到声音”。
            try Task.checkCancellation()
            if isCancelled {
                player.pause()
                return
            }

            // 4. 时间观察（更高频率让插值更准）；先 remove 旧 observer，避免切歌后旧回调残留
            if let token = timeObserverToken {
                player.removeTimeObserver(token)
                timeObserverToken = nil
            }
            timeObserverToken = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                guard let self else { return }
                let t = time.seconds.isFinite ? time.seconds : 0
                self.currentTime = t
                self.currentTimeUpdatedAt = Date()
                if let dur = self.avPlayer?.currentItem?.duration, dur.isNumeric, dur.seconds.isFinite {
                    self.duration = dur.seconds
                }
                // pre-end 触发点检查
                self.maybeFirePreEndCompute()
            }

            // 5. 播放结束：先 remove 旧 observer 再 add 新的，避免切歌后旧通知被错误触发
            if let token = endObserverToken {
                NotificationCenter.default.removeObserver(token)
                endObserverToken = nil
            }
            let itemForObserver = item
            endObserverToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: itemForObserver,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // 只在当前 avPlayer 持有的就是触发通知的 item 时才回调，
                // 防止旧 item 在 deinit 期间发出的 end 通知被误触
                guard self.avPlayer?.currentItem === itemForObserver else { return }
                self.isPlaying = false
                self.onCurrentVideoEnd?()
            }

            // observers 都装好了，player.play() 之前再拍一次快照，
            // 防止“observer 装好之后、play 之前”被 view 退出。
            try Task.checkCancellation()
            if isCancelled {
                player.pause()
                return
            }

            // 6. 自动开始（如果有续播进度且没看完，先 seek）
            currentTimeUpdatedAt = Date()
            if let resume = initialResumeSeconds,
               resume > 5,
               duration <= 0 || resume < duration - 5 {
                let target = CMTime(seconds: resume, preferredTimescale: 600)
                await player.seek(to: target)
                currentTime = resume
                AppLogger.info("Player: resuming from \(Int(resume))s")
            }
            player.play()
            isPlaying = true
            scheduleControlsHide()

            // 7. 异步加载弹幕（不阻塞播放）。
            // 用 [weak self] 避免 view 退出后这个 task 仍然强引用 vm，让 avPlayer 被拖在后台继续播。
            // 用 currentCid 而不是 detail.cid: 切歌 / 切 P 时拿当前播放分 P 的弹幕
            let danmakuCid = currentCid
            Task { [weak self] in await self?.loadDanmaku(cid: danmakuCid) }

            // 8. 从本地 VideoRecord 查合集视频列表（路径 1）
            // - 此时 video.ugcSeasonID 已经被 fetchVideoDetail 写回
            // - 本地查不到是正常的(没人播过这条合集里其他视频), 用户可以手动点开其他合集视频补全
            loadCollectionFromLocal()
        } catch {
            loadError = error.localizedDescription
            AppLogger.error("Player load failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 弹幕

    private func loadDanmaku(cid: Int) async {
        // 抖音没有公开的弹幕 API,跳过避免无谓 400
        guard cid > 0 else {
            AppLogger.info("Player: 抖音视频跳过 B 站弹幕加载(无公开 API)")
            return
        }
        do {
            let xml = try await BilibiliAPIService.shared.fetchVideoDanmaku(cid: cid)
            let messages = parseDanmakuXML(xml)
            self.allDanmaku = messages
            AppLogger.info("Player: loaded \(messages.count) danmaku for cid=\(cid)")
        } catch {
            AppLogger.error("Player: danmaku load failed: \(error.localizedDescription)")
        }
    }

    /// 解析 B 站弹幕 XML 为 VideoDanmaku
    /// <d p="time,type,fontsize,color,timestamp,pool,user_hash,id">content</d>
    /// type: 1=滚动 4=底部 5=顶部 6=逆向 7=精准 8=高级
    /// 轨道分配不在这里做 — 由 DanmakuFloatingView 在 view 层用真实 screenWidth 算 (支持 rotation)
    private func parseDanmakuXML(_ xml: String) -> [VideoDanmaku] {
        var result: [VideoDanmaku] = []
        let pattern = #"<d p="([^"]+)">([^<]*)</d>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsrange = NSRange(xml.startIndex..., in: xml)
        regex.enumerateMatches(in: xml, range: nsrange) { match, _, _ in
            guard let match = match, match.numberOfRanges == 3,
                  let pRange = Range(match.range(at: 1), in: xml),
                  let tRange = Range(match.range(at: 2), in: xml) else { return }
            let p = String(xml[pRange])
            let text = String(xml[tRange])
            if text.isEmpty { return }
            let parts = p.split(separator: ",")
            guard let timeStr = parts.first, let time = Double(timeStr) else { return }
            let danmakuType = parts.count >= 2 ? Int(parts[1]) ?? 1 : 1
            let colorHex = parts.count >= 4 ? UInt32(parts[3]) ?? 0xFFFFFF : 0xFFFFFF
            let kind: VideoDanmaku.Kind
            switch danmakuType {
            case 4: kind = .bottom
            case 5: kind = .top
            case 6: kind = .reverse
            default: kind = .scroll
            }
            // 弹幕自然宽度（CJK 1.0 / ASCII 0.55 字符单位 × 基础字号 40）
            // 实际渲染时如果超长会按屏幕宽度截断，这里用自然宽度参与碰撞检测
            let textWidth = DanmakuTrackAssigner.widthUnits(of: text) * 40
            result.append(VideoDanmaku(
                id: UUID(),
                videoTime: time,
                text: text,
                color: colorHex,
                kind: kind,
                textWidth: textWidth
            ))
        }
        // 按 videoTime 排序（XML 通常已是这个顺序，但保险起见排一下）
        result.sort { $0.videoTime < $1.videoTime }
        return result
    }

    // MARK: - 退出 / 释放

    /// View 退出时调用：标记 load() 不要再 player.play()，暂停并释放 player + observers，关闭音频会话。
    /// 之后即使 load() 在 await 之后才被调度执行，也只会因 isCancelled 提前 return。
    func tearDown() {
        isCancelled = true
        hideControlsTask?.cancel()
        preEndTask?.cancel()
        preEndTask = nil
        lastBackgroundAt = nil
        if let token = timeObserverToken {
            avPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
        currentItemForKVO = nil  // Combine sink 由 cancellables 管理,自动取消
        avPlayer?.pause()
        avPlayer = nil
        // 关掉音频会话，避免后台继续持有音频焦点。
        // 注意：playback 模式下 .notifyOthersOnDeactivation 让其他 app 能正常接管音频。
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 切后台 / 切回前台

    /// 切到后台时由 VideoPlayerView 触发：记录切走时刻。
    /// 切回前台时由 VideoPlayerView 触发：重置 currentTimeUpdatedAt，让弹幕 wallDelta
    /// 从切回前台开始累加 → videoTime = currentTime + (now - lastUpdate) 等于"切回前台时的 videoTime 起点"，
    /// 配合 player 在后台推进的 currentTime → 弹幕从切走时的位置继续飘（不跳到未来）
    func handleScenePhase(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            lastBackgroundAt = Date()
        case .active:
            if lastBackgroundAt != nil {
                // 重置 lastUpdate wall time：让 wallDelta 从 0 开始累加
                currentTimeUpdatedAt = Date()
                lastBackgroundAt = nil
            }
        case .inactive:
            // 短暂失去焦点（控制中心、通知中心等），UI 还在，不处理
            break
        @unknown default:
            break
        }
    }

    // MARK: - 控制

    func togglePlay() {
        guard let player = avPlayer else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        currentTimeUpdatedAt = Date()
        isPlaying.toggle()
        scheduleControlsHide()
    }

    func seek(to seconds: Double) {
        guard let player = avPlayer else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target)
        currentTime = seconds
        currentTimeUpdatedAt = Date()
    }

    func toggleFullscreen() {
        let targetLandscape = !isFullscreen
        isFullscreen = targetLandscape
        if targetLandscape {
            AppOrientationHelper.setOrientation(.landscape)
        } else {
            AppOrientationHelper.setOrientation(.portrait)
        }
    }

    func toggleDanmaku() {
        danmakuEnabled.toggle()
        scheduleControlsHide()
    }

    func tapSurface() {
        showControls.toggle()
        if showControls { scheduleControlsHide() }
    }

    func toggleFavorite() {
        isFavorited.toggle()
        scheduleControlsHide()
    }

    /// 切换到另一个视频（用于播放列表自动连播）
    /// 停止当前播放 → 重置状态 → 加载新视频
    func switchVideo(_ video: VideoItem) {
        // 切歌前先清掉旧 observer 和旧 player 的时间观察器，
        // 避免旧 item 在 deinit 时发出 end 通知被新回调误处理
        avPlayer?.pause()
        if let token = timeObserverToken {
            avPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
        avPlayer = nil
        allDanmaku = []
        currentTime = 0
        currentTimeUpdatedAt = Date()
        duration = 0
        loadError = nil
        quality = 0
        // 切歌后让 onCurrentVideoEnd 暂不触发（load 完成后再由 View 重新设置）
        let savedCallback = onCurrentVideoEnd
        onCurrentVideoEnd = nil
        // 切歌时清掉上一个视频的续播标记；新视频由 View 在 load 前重新设置
        initialResumeSeconds = nil
        // 切歌时也清掉历史里读到的 partCid(切到不同 aid 后,旧 partCid 已无意义)
        resumePartCid = 0
        // 切歌时清掉合集 / 推荐 状态；load 后会重新拉（如果新视频还在合集里）
        seasonPlaylist = nil
        seasonMeta = nil
        seasonCurrentIndex = 0
        // 切歌时也清掉分 P（新视频可能完全不同的 BV 号）
        parts = nil
        currentPartIndex = 0
        pendingRecommendations = nil
        preEndTriggerFired = false
        preEndTask?.cancel()
        preEndTask = nil
        isComputingRecommendations = false
        self.video = video
        Task { [weak self] in
            await self?.load()
            // load 完成后恢复回调
            self?.onCurrentVideoEnd = savedCallback
        }
    }

    /// 切换到指定分 P（0-based 索引, 用于 sheet 点选 / 上一首下一首 / 自动连播）
    /// - 区别于 switchVideo: video 本身不变, 只是同一个 BV 号下换到另一个分 P
    /// - 复用 load() 的整条流程: 重置 player + 拿新 cid 的 play URL + 加载新弹幕
    /// - 与切歌一样, onCurrentVideoEnd 暂存后恢复（避免旧 item deinit 时 end 通知误触）
    func switchToPart(at index: Int) {
        guard let parts = parts, index >= 0, index < parts.count else {
            AppLogger.error("Player: switchToPart 越界 index=\(index) parts.count=\(parts?.count ?? 0)")
            return
        }
        guard index != currentPartIndex else { return }
        let oldIndex = currentPartIndex
        currentPartIndex = index
        AppLogger.info("Player: switchToPart \(oldIndex) -> \(index), cid=\(parts[index].cid)")

        avPlayer?.pause()
        if let token = timeObserverToken {
            avPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
        avPlayer = nil
        allDanmaku = []
        currentTime = 0
        currentTimeUpdatedAt = Date()
        duration = 0
        loadError = nil
        quality = 0
        // 切 P 不续播：分 P 之间相互独立
        initialResumeSeconds = nil
        // 切 P 时清掉历史 partCid 标记,避免后续逻辑误判
        resumePartCid = 0
        // 推荐预计算保持不变(同一视频, 仍可用)
        preEndTriggerFired = false
        preEndTask?.cancel()
        preEndTask = nil
        let savedCallback = onCurrentVideoEnd
        onCurrentVideoEnd = nil
        Task { [weak self] in
            await self?.load()
            self?.onCurrentVideoEnd = savedCallback
        }
    }

    // MARK: - 播下一个：合集 / 本地推荐 / DeepSeek

    /// 从本地 VideoRecord 加载合集视频列表
    /// - 不再调合集 API(只返回前 30 个, 不分页; 用本地数据看到全量)
    /// - 查找所有 `ugcSeasonID == video.ugcSeasonID` 的本地视频, 按 publishTime 升序
    /// - 合集标题取第一条记录(同一合集内所有视频的 ugcSeasonTitle 都应该一致)
    /// - 限制: 只有"播放过 fetchVideoDetail"的视频才会有 ugcSeasonID, 否则不出现
    ///   这是已知的限制 — 想要补全得手动点开更多合集视频

    /// 强制刷新合集播放列表（供外部触发，如手动补全完成后）
    func refreshSeasonPlaylist() {
        seasonPlaylist = nil
        loadCollectionFromLocal(triggerBackfill: false)
    }
    func loadCollectionFromLocal(triggerBackfill: Bool = true) {
        guard AppSettings.seasonAutoplayEnabled else {
            AppLogger.info("Player: season autoplay disabled, skip")
            return
        }
        guard let seasonID = video.ugcSeasonID, seasonID > 0 else { return }
        guard seasonPlaylist == nil else { return }
        guard let ctx = modelContext else {
            AppLogger.info("Player: 没有 modelContext, 跳过合集本地查")
            return
        }
        let currentAid = video.aid
        let currentAuthorName = video.authorName
        let currentAuthorAvatar = video.authorAvatar
        // SwiftData predicate: 不能直接用 seasonID(Int?) 做比较, 用 let 绑定一下
        let seasonIDValue = seasonID
        let descriptor = FetchDescriptor<VideoRecord>(
            predicate: #Predicate { $0.ugcSeasonID == seasonIDValue },
            sortBy: [SortDescriptor(\.publishTime, order: .forward)]
        )
        let records: [VideoRecord]
        do {
            records = try ctx.fetch(descriptor)
        } catch {
            AppLogger.error("Player: 合集本地查失败: \(error.localizedDescription)")
            return
        }
        let currentIdx = records.firstIndex { $0.aid == currentAid } ?? 0
        // 合集标题: 取第一条有 ugcSeasonTitle 的(都应该是同一个合集, 标题一致)
        let seasonName = records.compactMap { $0.ugcSeasonTitle }.first ?? "合集"
        self.seasonMeta = SeasonMeta(
            seasonID: seasonID,
            name: seasonName,
            cover: records.first?.coverURL,
            total: records.count
        )
        self.seasonPlaylist = records.map { record in
            // authorName/Avatar 用当前视频的(合集都是同一个 UP 主)
            VideoItem(
                id: String(record.aid),
                aid: record.aid,
                bvid: record.bvid,
                cid: 0,  // 进播放时再 fetchVideoDetail 拿
                title: record.title,
                coverURL: record.coverURL,
                playURL: "",
                webURL: record.webURL,
                duration: record.duration,
                publishTime: record.publishTime,
                viewCount: record.viewCount,
                danmakuCount: record.danmakuCount,
                commentCount: record.commentCount,
                authorUID: record.authorUID,
                authorName: record.authorName.isEmpty ? currentAuthorName : record.authorName,
                authorAvatar: record.authorAvatar.isEmpty ? currentAuthorAvatar : record.authorAvatar,
                platform: record.platform,
                ugcSeasonID: record.ugcSeasonID,
                ugcSeasonTitle: record.ugcSeasonTitle
            )
        }
        self.seasonCurrentIndex = currentIdx
        AppLogger.info("Player: 合集 season_id=\(seasonID) 本地查 \(self.seasonPlaylist?.count ?? 0) 个, 当前在 index=\(currentIdx)")

        // 自动触发: 异步拉合集 API 第一页, 跟本地匹配, 写回 ugcSeasonID/Title
        // - 完成后 seasonPlaylist 自动变长(重新查本地)
        // - 关闭开关(seasonAutoBackfillEnabled)就只走手动
        // - debounce: 同一个 seasonID 60s 内只触发一次(防止 backfill 完成后递归触发)
        // 自动触发: 异步拉合集 API 第一页, 跟本地匹配, 写回 ugcSeasonID/Title
        // - 60s debounce 在 SeasonBackfillService.backfillOne 内部(静态, 跨 VM 共享)
        // - 关闭开关(seasonAutoBackfillEnabled)就只走手动
        if triggerBackfill && AppSettings.seasonAutoBackfillEnabled {
            let capturedMid = video.authorUID
            let capturedSeasonID = seasonID
            Task { [weak self] in
                guard let self else { return }
                guard let ctx = self.modelContext else { return }
                let n = await SeasonBackfillService.backfillOne(
                    mid: capturedMid, seasonID: capturedSeasonID, in: ctx, fetchAll: false
                )
                await MainActor.run {
                    // 防止用户在 backfill 过程中切到别的视频
                    guard self.video.ugcSeasonID == capturedSeasonID else { return }
                    if n > 0 {
                        AppLogger.info("Player: backfill 实际新匹配 \(n) 个, 刷新 seasonPlaylist")
                        // 关键: triggerBackfill: false 避免递归触发 backfill
                        self.seasonPlaylist = nil
                        self.loadCollectionFromLocal(triggerBackfill: false)
                    }
                }
            }
        }
    }

    /// 检查是否到了 pre-end 时间点, 触发「推荐」预计算
    /// - 由 periodic time observer 每 0.25s 调用一次
    /// - 只 fire 一次(切歌/重新 load 后重置)
    /// - 当前视频有合集时跳过(合集已能自动连播, 不用推荐兜底)
    func maybeFirePreEndCompute() {
        guard !preEndTriggerFired else { return }
        guard AppSettings.aiRecommendEnabled else { return }
        // 有合集时不用算推荐
        if let s = seasonPlaylist, s.count > 1 { return }
        guard duration > 0, currentTime > 0 else { return }
        let remaining = duration - currentTime
        // 60s 窗口; 视频时长 < 90s 的不预计算(刚 load 就直接结束了)
        guard remaining > 0, remaining < 60, duration > 90 else { return }
        guard let context = modelContext else { return }
        preEndTriggerFired = true
        AppLogger.info("Player: pre-end trigger fired (remaining=\(Int(remaining))s)")
        preEndTask = Task { [weak self] in
            await self?.computePreEndRecommendations(context: context)
        }
    }

    /// 计算「播完后推荐」视频
    /// - 模式: 由 AppSettings.localRecommendMode 决定 (vector / deepseek)
    /// - 结果写入 pendingRecommendations, View 读这个 @Published 来展示
    private func computePreEndRecommendations(context: ModelContext) async {
        guard !isComputingRecommendations else { return }
        isComputingRecommendations = true
        defer {
            Task { @MainActor in self.isComputingRecommendations = false }
        }
        let current = video
        do {
            let recs: [VideoItem]
            switch AppSettings.localRecommendMode {
            case .vector:
                recs = try await RecommendationService.recommendForLocalVector(
                    currentVideo: current, in: context
                )
            case .deepseek:
                recs = try await RecommendationService.recommendForDeepSeek(
                    currentVideo: current, in: context
                )
            }
            await MainActor.run {
                self.pendingRecommendations = recs
                AppLogger.info("Player: pre-end compute done, got \(recs.count) recommendations")
            }
        } catch {
            AppLogger.error("Player: pre-end compute failed: \(error.localizedDescription)")
            // 失败不要让用户看到半截数据
        }
    }

    /// 用户在播放器里点了「AI 智能推荐」按钮, 主动跑一次 DeepSeek(忽略本地模式)
    /// - 用于「我已经配了 DeepSeek key, 想用 LLM 推荐」的入口
    /// - 也用于「库很小 / 向量还没建好」的兜底
    func runAIRecommendNow() {
        guard let context = modelContext else {
            AppLogger.error("Player: runAIRecommendNow, no modelContext")
            return
        }
        guard AppSettings.hasDeepSeekAPIKey else {
            AppLogger.error("Player: runAIRecommendNow, no DeepSeek key")
            return
        }
        Task { [weak self] in
            await self?.computePreEndRecommendations(context: context)
        }
    }

    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled && isPlaying {
                showControls = false
            }
        }
    }
}

/// 设备方向辅助
enum AppOrientationHelper {
    static func setOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        } else {
            UIDevice.current.setValue(mask.toRaw(), forKey: "orientation")
        }
    }
}

extension UIInterfaceOrientationMask {
    func toRaw() -> Int {
        switch self {
        case .portrait: return 1
        case .landscape: return 3
        case .portraitUpsideDown: return 2
        case .allButUpsideDown: return 3
        default: return 1
        }
    }
}
