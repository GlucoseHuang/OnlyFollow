import Foundation
import MediaPlayer
import UIKit

/// 把当前播放状态投影到 iOS 系统"控制中心 / 锁定屏 widget"。
///
/// 设计要点：
/// - 单例 + 显式 `register()` / `unregister()`：每次进入播放器时 wire up 一次，
///   离开时全清；这样不会跨页面泄漏闭包/observer。
/// - 命令回调（onPlay / onPause / ...）由调用方注入；本类只做"系统 ↔ 闭包"的桥。
/// - 元数据（title / artist / duration / elapsed / rate）由 `update(...)` 写入
///   `MPNowPlayingInfoCenter.default().nowPlayingInfo`。
/// - 不实现 AirPlay 路由选择器（用户 v0.1 明确要求延后），所以 `MPRemoteCommandCenter`
///   只挂 play / pause / togglePlayPause / nextTrack / previousTrack 这五个命令。
@MainActor
final class NowPlayingController {
    static let shared = NowPlayingController()

    // MARK: - 调用方注入的回调

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onPreviousTrack: (() -> Void)?

    // MARK: - 状态

    private(set) var isRegistered = false

    /// 当前"是否还有下一首/上一首"——控制中心 next/prev 按钮可用性。
    /// 调用方（播放器）在 playlist 变化 / 切歌时更新这两个值。
    var hasNextTrack: Bool = false
    var hasPreviousTrack: Bool = false

    /// 缓存已经下下来的封面图（coverURL -> MPMediaItemArtwork），避免切歌反复拉。
    private var artworkCache: [String: MPMediaItemArtwork] = [:]

    private init() {}

    // MARK: - 注册 / 注销

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            self?.dispatchOnMain { self?.onPlay?() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.dispatchOnMain { self?.onPause?() }
            return .success
        }
        // togglePlayPause 让系统决定该 play 还是 pause（看锁屏图标）
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.dispatchOnMain { self?.onTogglePlayPause?() }
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.dispatchOnMain { self?.onNextTrack?() }
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.dispatchOnMain { self?.onPreviousTrack?() }
            return .success
        }

        // v0.1 不做快进/快退/拖动定位；先关掉，避免误触
        cc.skipForwardCommand.isEnabled = false
        cc.skipBackwardCommand.isEnabled = false
        cc.changePlaybackPositionCommand.isEnabled = false
        cc.seekForwardCommand.isEnabled = false
        cc.seekBackwardCommand.isEnabled = false
    }

    func unregister() {
        guard isRegistered else { return }
        isRegistered = false
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.nextTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.removeTarget(nil)

        clear()
        onPlay = nil
        onPause = nil
        onTogglePlayPause = nil
        onNextTrack = nil
        onPreviousTrack = nil
    }

    /// 主动清掉控制中心里的元数据（播放页关闭时调用，避免控制中心还显示着旧信息）。
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = false
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = false
    }

    // MARK: - 元数据

    /// 把当前播放快照写入控制中心。封面图异步加载，加载完后会 patch 进 already-written dict。
    func update(
        title: String,
        artist: String,
        artworkURL: String?,
        duration: TimeInterval,
        elapsed: TimeInterval,
        rate: Double
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]

        // 先把缓存里的封面塞进去（如果有）
        let normalizedURL = artworkURL.flatMap { ensureHTTPS($0) }
        if let key = normalizedURL, let cached = artworkCache[key] {
            info[MPMediaItemPropertyArtwork] = cached
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // 异步加载封面，加完回写
        if let key = normalizedURL, artworkCache[key] == nil,
           let url = URL(string: key) {
            loadArtwork(url: url, cacheKey: key)
        }

        // 同步 prev / next 命令的可用性
        let cc = MPRemoteCommandCenter.shared()
        cc.nextTrackCommand.isEnabled = hasNextTrack
        cc.previousTrackCommand.isEnabled = hasPreviousTrack
    }

    private func loadArtwork(url: URL, cacheKey: String) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                await MainActor.run {
                    self.artworkCache[cacheKey] = artwork
                    // patch 进已经写过的 info,不要整体重写(避免覆盖正在变化的 elapsed/rate)
                    var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    current[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = current
                }
            } catch {
                // 封面加载失败不致命,系统会用占位图
            }
        }
    }

    // MARK: - 辅助

    /// MPRemoteCommandCenter 的回调可能在后台线程,把闭包调用 re-dispatch 到主 actor
    /// ——onXxx 闭包的目标(如 vm.togglePlay)都是 @MainActor 的。
    private func dispatchOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            Task { @MainActor in block() }
        }
    }
}
