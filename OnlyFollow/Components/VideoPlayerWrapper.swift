import SwiftUI
import AVKit

/// 把 AVPlayer 渲染到 UIView 上的 UIViewRepresentable 包装
/// 用 AVPlayerLayer 而不是 AVPlayerViewController，因为我们要自定义 UI
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
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
