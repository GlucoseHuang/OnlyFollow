import UIKit
import SwiftUI
import SwiftData

/// 用 UIKit 直接 present 视频播放器，绕开 SwiftUI .fullScreenCover 的方向限制
/// - supportedInterfaceOrientations = .all 让播放器可以自由旋转到横屏
/// - 模态层级的旋转请求不会被父容器的 orientation mask 覆盖
@MainActor
enum PlayerPresenter {
    /// 从任意可用的 view controller 上 present 视频播放器
    /// - Parameter modelContext: 必须由调用方从自己的 SwiftUI 环境里传进来——
    ///   独立 UIHostingController 里 @Environment(\.modelContext) 不可靠（拿到的是与全局 store 不通的 context，
    ///   所有 SwiftData 操作会被静默吞掉），所以这里强制要求显式传入。
    static func present(_ video: VideoItem, modelContext: ModelContext) {
        let playerView = VideoPlayerView(video: video, modelContext: modelContext)
        let host = OrientationFreeHostingController(rootView: playerView)
        host.modalPresentationStyle = .fullScreen
        host.modalTransitionStyle = .crossDissolve

        guard let presenter = topMostViewController() else {
            AppLogger.error("PlayerPresenter: 找不到顶层 view controller")
            return
        }
        presenter.present(host, animated: true)
    }

    /// 找当前活跃 window 的 key window 的 root view controller
    private static func topMostViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    }
}

/// 关键：UIHostingController 子类，覆盖 supportedInterfaceOrientations
/// SwiftUI 的 .fullScreenCover 内部的 hosting controller 用默认 mask（继承自 presenter）
/// 自己 present 的 hosting controller 我们可以指定 .all
final class OrientationFreeHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 监听 dismiss，自动还原为竖屏（保险起见）
        view.backgroundColor = .black
    }
}
