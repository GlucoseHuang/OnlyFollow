import SwiftUI
import MediaPlayer
import AVFoundation
import UIKit

/// 系统音量的控制器(用 MPVolumeView 内部 slider 调系统音量)
///
/// 原理：
/// - iOS 不允许第三方 App 直接改 `AVAudioSession.outputVolume` 来"写入"音量
/// - 标准做法是放一个 `MPVolumeView` 到视图层级里(它有 internal UISlider),
///   然后用 KVC 改 `value`
/// - 关键: MPVolumeView 必须**在 view hierarchy 中**(哪怕是 frame=0 / offscreen)
///   iOS 才会把这个 slider 当成"系统音量入口",否则改 value 无效
///
/// 用法：
/// ```swift
/// // 在 onAppear / task 里 attach 一次
/// SystemVolumeController.shared.attach(to: uiWindow)
/// // 调音量
/// SystemVolumeController.shared.setVolume(0.5)
/// ```
@MainActor
final class SystemVolumeController {
    static let shared = SystemVolumeController()

    /// 内部 MPVolumeView:0 尺寸,加在主 window 上(必须,否则写不进系统音量)
    private var volumeView: MPVolumeView?
    /// 原始音量缓存(用于避免重复设值, MPVolumeView 改 value 会有系统弹 HUD)
    private var lastValue: Float?

    private init() {}

    /// 把 volumeView 加到 keyWindow 上(只在第一次调用时加,后续是 no-op)
    /// - 必须从主线程调用
    /// - 如果 keyWindow 还没好(比如 onAppear 太早),会等一下
    func attach() {
        guard volumeView == nil else { return }
        let v = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 0, height: 0))
        v.alpha = 0.001
        v.isUserInteractionEnabled = false
        v.showsRouteButton = false
        v.showsVolumeSlider = true
        v.sizeToFit()
        // 必须挂到一个真实 window 上,iOS 才会把它的 slider 注册到系统
        if let window = Self.keyWindow() {
            window.addSubview(v)
        } else {
            // 还没拿到 window,等一帧再试
            DispatchQueue.main.async { [weak self] in
                self?.attach()
            }
            return
        }
        volumeView = v
        AppLogger.info("VolumeCtrl: MPVolumeView attached, hidden offscreen")
    }

    /// 从 window 上摘掉(view 销毁时调用,避免泄漏)
    func detach() {
        volumeView?.removeFromSuperview()
        volumeView = nil
        lastValue = nil
    }

    /// 当前系统音量(0~1)
    var current: Float {
        // AVAudioSession.outputVolume 是只读的,但能可靠反映系统音量
        return AVAudioSession.sharedInstance().outputVolume
    }

    /// 设置系统音量(0~1)
    /// - 会触发系统 HUD 显示(系统行为,无法避免,这是符合用户预期的)
    func setVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else {
            AppLogger.warning("VolumeCtrl: no UISlider found in MPVolumeView, did you call attach()?")
            return
        }
        // slider.value 改完会触发 MPVolumeView 内部把值传回 AVAudioSession
        // performWithoutAnimation 避免某些 iOS 版本上对 slider 的视觉插值
        UIView.performWithoutAnimation {
            slider.value = clamped
        }
        lastValue = clamped
    }

    private static func keyWindow() -> UIWindow? {
        // iOS 13+: keyWindow 在 UIApplication 上,但有时需要遍历 scenes
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let key = ws.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            if let first = ws.windows.first {
                return first
            }
        }
        return nil
    }
}
