import SwiftUI
import UIKit

/// 播放页手势 + 浮层指示器
///
/// - 屏幕**左侧**上下滑 → 系统屏幕亮度 (`UIScreen.main.brightness`)
/// - 屏幕**右侧**上下滑 → 系统音量 (`SystemVolumeController`, 走 `MPVolumeView` 内部 slider)
/// - 屏幕**水平滑**(仅当 `supportsSeek == true`) → 调视频进度, callback `onSeek(newTime)`
///
/// 手感参数(可调):
/// - 垂直:**屏幕半高**对应 0~1 全量调整(iOS 系统的滑块感觉)
/// - 水平:**1 pt = 0.1s**(拖 100pt = ±10s)
/// - 拖动方向一旦锁定,本次手势不再切换
///
/// 与现有 `onTapGesture` 的兼容:
/// - `minimumDistance: 5` 让短按不被识别成 drag
/// - tap 不会被 drag 触发,drag 也不会触发 tap
struct PlaybackGestureModifier: ViewModifier {
    /// 是否启用(锁定时传 false)
    var enabled: Bool
    /// 是否支持水平拖动调进度(直播为 false)
    var supportsSeek: Bool
    /// 视频总时长(秒)
    var duration: Double
    /// 当前播放位置(秒)
    var currentTime: Double
    /// seek 实时回调: 接收目标秒数
    var onSeek: (Double) -> Void

    @State private var startLocation: CGPoint? = nil
    @State private var initialBrightness: CGFloat? = nil
    @State private var initialVolume: Float? = nil
    @State private var initialSeekTime: Double? = nil
    @State private var lastSeekAt: Date = .distantPast
    @State private var containerSize: CGSize = .zero
    @State private var axis: GestureAxis? = nil
    @State private var indicator: GestureIndicator? = nil
    @State private var isDragging: Bool = false
    @State private var hideTask: Task<Void, Never>? = nil

    enum GestureAxis { case vertical, horizontal }

    /// 参考尺寸: 优先用 GeometryReader 拿到的真实 content size, 拿不到时回退到屏幕 size
    /// (避免之前那种 `.background(GeometryReader { Color.clear })` 拿不到 size 的坑)
    private var referenceSize: CGSize {
        if containerSize.width > 0, containerSize.height > 0 {
            return containerSize
        }
        return UIScreen.main.bounds.size
    }

    func body(content: Content) -> some View {
        content
            // overlay(GeometryReader{Color.clear}) 一定铺满父 view, 比 .background 可靠
            .overlay(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: SizePrefKey.self, value: proxy.size)
                }
                .allowsHitTesting(false)
            )
            .onPreferenceChange(SizePrefKey.self) { newSize in
                if newSize.width > 0, newSize.height > 0 {
                    containerSize = newSize
                }
            }
            .onAppear { containerSize = UIScreen.main.bounds.size }
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .local)
                    .onChanged { value in
                        guard enabled else { return }
                        handleChanged(value)
                    }
                    .onEnded { _ in handleEnded() }
            )
            .overlay(alignment: .center) {
                if isDragging, let ind = indicator {
                    GestureIndicatorView(indicator: ind)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: isDragging)
    }

    // MARK: - 手势逻辑

    private func handleChanged(_ value: DragGesture.Value) {
        if startLocation == nil {
            // 拖动起点
            startLocation = value.startLocation
            initialBrightness = CGFloat(UIScreen.main.brightness)
            initialVolume = SystemVolumeController.shared.current
            initialSeekTime = currentTime
            isDragging = true
            hideTask?.cancel()
        }

        let dx = value.location.x - (startLocation?.x ?? 0)
        let dy = value.location.y - (startLocation?.y ?? 0)
        let absDx = abs(dx), absDy = abs(dy)

        // 锁定方向(锁定后本次手势不再切换)
        if axis == nil {
            if absDy > 14 && absDy > absDx * 1.4 {
                axis = .vertical
            } else if absDx > 14 && absDx > absDy * 1.4, supportsSeek {
                axis = .horizontal
            }
        }

        switch axis {
        case .vertical:
            applyVertical(dy: dy)
        case .horizontal:
            applyHorizontal(dx: dx)
        case .none:
            return
        }
    }

    private func applyVertical(dy: CGFloat) {
        let size = referenceSize
        // 屏幕半高 = 0~1 全量调整(感觉跟 iOS 亮度调节条一致)
        let span = max(size.height / 2, 1)
        // 上滑(dy<0)= 增亮/增音; 用 -dy 让上滑 = 正
        let ratio = Double(-dy / span)
        let startX = startLocation?.x ?? 0
        let isLeftHalf = startX < size.width / 2

        if isLeftHalf, let b0 = initialBrightness {
            let newB = max(0, min(1, b0 + ratio))
            UIScreen.main.brightness = CGFloat(newB)
            indicator = .brightness(newB)
        } else if !isLeftHalf, let v0 = initialVolume {
            let newV = max(0, min(1, v0 + Float(ratio)))
            SystemVolumeController.shared.setVolume(newV)
            indicator = .volume(newV)
        }
    }

    private func applyHorizontal(dx: CGFloat) {
        guard supportsSeek, let t0 = initialSeekTime, duration > 0 else { return }
        // 1 pt ≈ 0.1s (手感参数, 可调)
        let deltaSeconds = Double(dx) * 0.1
        let newTime = max(0, min(duration, t0 + deltaSeconds))
        indicator = .seek(delta: newTime - t0, target: newTime, duration: duration)
        // 节流: 80ms 一次 seek(避免每个像素都触发 AVPlayer.seek)
        let now = Date()
        if now.timeIntervalSince(lastSeekAt) > 0.08 {
            onSeek(newTime)
            lastSeekAt = now
        }
    }

    private func handleEnded() {
        isDragging = false
        startLocation = nil
        initialBrightness = nil
        initialVolume = nil
        initialSeekTime = nil
        axis = nil
        hideTask?.cancel()
        // 0.5s 后淡出浮层
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            indicator = nil
        }
    }
}

// MARK: - 浮层

enum GestureIndicator: Equatable {
    case brightness(CGFloat)
    case volume(Float)
    case seek(delta: Double, target: Double, duration: Double)
}

private struct SizePrefKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct GestureIndicatorView: View {
    let indicator: GestureIndicator

    var body: some View {
        HStack(spacing: 14) {
            switch indicator {
            case .brightness(let v):
                Image(systemName: brightnessIcon(v))
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: 120, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.white)
                            .frame(width: max(0, min(1, Double(v))) * 120, height: 4)
                    }
            case .volume(let v):
                Image(systemName: volumeIcon(v))
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: 120, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.white)
                            .frame(width: max(0, min(1, Double(v))) * 120, height: 4)
                    }
            case .seek(let delta, let target, let duration):
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: delta >= 0 ? "forward.fill" : "backward.fill")
                            .font(.system(size: 18, weight: .medium))
                        Text(formatSeconds(abs(delta)))
                            .font(.subheadline.bold().monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    HStack(spacing: 4) {
                        Text(formatSeconds(target))
                        Text("/")
                        Text(formatSeconds(duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.7), in: .rect(cornerRadius: 14))
        .shadow(radius: 10)
    }

    private func formatSeconds(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "00:00" }
        let i = Int(s)
        return String(format: "%02d:%02d", i / 60, i % 60)
    }

    private func brightnessIcon(_ v: CGFloat) -> String {
        if v < 0.01 { return "sun.min" }
        if v < 0.33 { return "sun.haze" }
        if v < 0.66 { return "sun.max" }
        return "sun.max.fill"
    }

    private func volumeIcon(_ v: Float) -> String {
        if v < 0.01 { return "speaker.slash.fill" }
        if v < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }
}

extension View {
    /// 给播放页加上"左右半屏上下滑调亮度/音量 + 水平滑调进度"的手势
    /// - Parameters:
    ///   - enabled: 锁定时传 false
    ///   - supportsSeek: 直播为 false, 视频为 true
    ///   - duration: 视频总时长(直播传 0)
    ///   - currentTime: 当前播放位置
    ///   - onSeek: seek 模式回调(传新的目标秒数)
    func playbackGestures(
        enabled: Bool,
        supportsSeek: Bool = false,
        duration: Double = 0,
        currentTime: Double = 0,
        onSeek: @escaping (Double) -> Void = { _ in }
    ) -> some View {
        modifier(PlaybackGestureModifier(
            enabled: enabled,
            supportsSeek: supportsSeek,
            duration: duration,
            currentTime: currentTime,
            onSeek: onSeek
        ))
    }
}
