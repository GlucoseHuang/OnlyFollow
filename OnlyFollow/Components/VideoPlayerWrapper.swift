import SwiftUI
import AVKit

/// 把 AVPlayer 渲染到 UIView 上的 UIViewRepresentable 包装
/// 用 AVPlayerLayer 而不是 AVPlayerViewController，因为我们要自定义 UI
///
/// **后台行为说明**：
/// - 切到后台时 playerLayer **不**做 detach（保留 player 引用）
/// - iOS 在 background 时自动冻结 view 渲染管线（屏幕必然黑屏）
/// - 切回前台时 view 重新合成，layer 状态 = 切走时的 last frame + 持续推进的 player → 画面**立即**显示
/// - 这样避免了"切回前台时重新绑定 player 导致重新解码第一帧产生的黑屏"
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.retainedPlayer = player
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        uiView.retainedPlayer = player
    }
}

final class PlayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// 强引用 player,避免外部没人持有时 AVPlayer 被销毁
    var retainedPlayer: AVPlayer?

    /// 手动把 player 从 layer 上摘掉(罕见用法,默认不会自动调用)
    func detach() {
        playerLayer.player = nil
    }

    /// 手动把 player 重新挂回 layer(罕见用法,默认不会自动调用)
    func reattach() {
        if let p = retainedPlayer, playerLayer.player !== p {
            playerLayer.player = p
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
