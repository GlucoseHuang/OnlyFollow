import Foundation
import SwiftUI
import AVKit
import AVFAudio
import Combine

/// 视频播放器视图模型
/// 职责：拉播放 URL → 加载弹幕 → 维护播放状态 → 暴露给 UI 绑定
@MainActor
final class VideoPlayerViewModel: ObservableObject {
    var video: VideoItem
    /// 进入播放页时由 View 从 PlaybackHistory 读出的续播位置。
    /// load() 完成后会自动 seek 到这里（前提是 >5s 且没看完）。
    var initialResumeSeconds: Double?

    @Published var avPlayer: AVPlayer?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    /// currentTime 上一次被 AVPlayer observer 写入的 wall time
    /// 弹幕渲染用它做插值，避免 AVPlayer 0.5s 采样导致 PPT 跳
    @Published private(set) var currentTimeUpdatedAt: Date = Date()
    @Published var duration: Double = 0
    @Published var loadError: String?
    @Published var showControls = true
    @Published var isFullscreen = false
    @Published var danmakuEnabled = true
    @Published var quality: Int = 0
    @Published var isFavorited: Bool = false

    /// 全部弹幕（按 videoTime 升序）
    @Published private(set) var allDanmaku: [VideoDanmaku] = []

    /// 当前视频正常播放结束回调（用于播放列表自动连播）
    /// 不通过 @Published 计数 + onChange 触发，避免旧 observer 残留导致重复触发
    var onCurrentVideoEnd: (() -> Void)?

    private var timeObserverToken: Any?
    private var endObserverToken: NSObjectProtocol?
    private var hideControlsTask: Task<Void, Never>?

    init(video: VideoItem) {
        self.video = video
    }

    // MARK: - 加载

    func load() async {
        do {
            // 0. 设置音频会话：category=.playback 让声音在静音模式下也能播放
            //    mode=.moviePlayback 优化视频音频体验
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
                try session.setActive(true, options: [])
            } catch {
                AppLogger.error("Player: audio session setup failed: \(error.localizedDescription)")
            }

            // 1. 拿 cid（如果还没有）
            var detail = video
            if detail.cid == 0 {
                let v = try await BilibiliAPIService.shared.fetchVideoDetail(aid: "\(detail.aid)")
                detail = v
            }

            // 2. 拿播放 URL
            let (urlStr, q) = try await BilibiliAPIService.shared.fetchVideoPlayURL(aid: "\(detail.aid)", cid: detail.cid)
            quality = q
            AppLogger.info("Player: playURL quality=\(q) url=\(urlStr.prefix(80))...")

            // 3. 设置 AVPlayer（带 B站 CDN 必需的 header）
            guard let url = URL(string: urlStr) else {
                throw APIError.parseError("invalid play url")
            }
            let headers: [String: String] = [
                "User-Agent": BilibiliSessionManager.kDefaultUserAgent,
                "Referer": "https://www.bilibili.com",
                "Cookie": BilibiliSessionManager.shared.cookieString
            ]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            self.avPlayer = player

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

            // 7. 异步加载弹幕（不阻塞播放）
            Task { await self.loadDanmaku(cid: detail.cid) }
        } catch {
            loadError = error.localizedDescription
            AppLogger.error("Player load failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 弹幕

    private func loadDanmaku(cid: Int) async {
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
            result.append(VideoDanmaku(
                id: UUID(),
                videoTime: time,
                text: text,
                color: colorHex,
                kind: kind
            ))
        }
        // 1) 先按 videoTime 排序（XML 通常已是这个顺序，但保险起见排一下）
        result.sort { $0.videoTime < $1.videoTime }
        // 2) 给滚动弹幕分配轨道，参考 B 站客户端的碰撞检测
        let trackMap = DanmakuTrackAssigner.assignTracks(to: result, lifetime: 6.0, trackCount: 5)
        for i in result.indices {
            if let track = trackMap[result[i].id] {
                result[i].track = track
            }
        }
        return result
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
        self.video = video
        Task { [weak self] in
            await self?.load()
            // load 完成后恢复回调
            self?.onCurrentVideoEnd = savedCallback
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
