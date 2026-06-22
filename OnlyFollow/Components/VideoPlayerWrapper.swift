import SwiftUI
import AVKit

/// 把 AVPlayer 渲染到 UIView 上的 UIViewRepresentable 包装
/// 用 AVPlayerLayer 而不是 AVPlayerViewController，因为我们要自定义 UI
///
/// **后台播放的关键**：
/// - 进入 `.inactive` / `.background` 前调 `detach()`，把 `playerLayer.player = nil`
/// - 回到 `.active` 时调 `reattach()`，再把 player 接回去
/// 这样 AVPlayer 本身不被释放，音频继续；AVPlayerLayer 不再持有 player，iOS 就不会
/// 因为"渲染目标不可见"而把整个 pipeline(包括音频)节流掉
/// 参考 https://www.mux.com/blog/background-audio-handling-with-ios-avplayer
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        // 强引用一份 player，否则 detach() 把 layer.player 置 nil 之后，
        // 如果外部也没有人持有这个 AVPlayer,AVFoundation 会立刻 dealloc,
        // 音频就没了。
        view.retainedPlayer = player
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        // 注意:这里不能无条件把 layer.player 重设回传入的 player;
        // detach 之后用户可能还没回来,这时强制 reattach 会破坏后台播放。
        // 让 VideoPlayerView 通过 Coordinator 显式调 detach/reattach
        uiView.retainedPlayer = player
    }

    /// 让 SwiftUI 找到这个 view 并调用 detach/reattach
    static func findHost(in view: UIView) -> PlayerHostView? {
        // 简单实现:递归找第一个 PlayerHostView
        if let host = view as? PlayerHostView { return host }
        for sub in view.subviews {
            if let host = findHost(in: sub) { return host }
        }
        return nil
    }
}

final class PlayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// 强引用 player,让 detach() 把 layer.player 置 nil 之后 AVPlayer 不会被销毁
    var retainedPlayer: AVPlayer?

    /// 后台/锁屏前调用:把 player 从 layer 上摘掉,但 player 实例继续活着,音频继续
    func detach() {
        playerLayer.player = nil
    }

    /// 回前台时调用:把 player 重新挂回 layer,UI 立刻有画面
    func reattach() {
        if let p = retainedPlayer, playerLayer.player !== p {
            playerLayer.player = p
        }
    }

    // MARK: - 自动监听 UIScene 生命周期

    /// 当前所有活跃 PlayerHostView,用来在调试时知道哪些 view 在 detach 状态
    private static var activeInstances: [ObjectIdentifier: PlayerHostView] = [:]

    /// scene lifecycle 监听只挂一次
    private static var sceneObserverInstalled = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // 第一个活跃实例负责注册 observer
            if !Self.sceneObserverInstalled {
                Self.installSceneObserver()
                Self.sceneObserverInstalled = true
            }
            Self.activeInstances[ObjectIdentifier(self)] = self
            // view 重新挂回窗口(从后台回来)→ reattach
            reattach()
        } else {
            Self.activeInstances.removeValue(forKey: ObjectIdentifier(self))
        }
    }

    private static func installSceneObserver() {
        // UIScene.willDeactivateNotification(将要退到 inactive/background)
        // → 这一刻 layer 即将被隐藏,马上 detach
        // UIScene.didActivateNotification(回到 active)
        // → 这一刻 layer 重新可见,reattach
        NotificationCenter.default.addObserver(
            forName: UIScene.willDeactivateNotification,
            object: nil,
            queue: .main
        ) { _ in
            for host in Self.activeInstances.values {
                host.detach()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { _ in
            for host in Self.activeInstances.values {
                host.reattach()
            }
        }
    }
}

/// 接受 URL 的便捷包装（用于直播流等已有直链的场景）
struct VideoPlayerWrapper: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = AVPlayer(url: url)
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {}
}
