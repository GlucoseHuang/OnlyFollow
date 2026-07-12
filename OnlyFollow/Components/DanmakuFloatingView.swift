import Foundation
import SwiftUI

/// 视频弹幕的内部表示
/// - videoTime: 出现时刻（视频秒数）
/// - kind: 滚动 / 顶部 / 底部（参考 B 站 type 字段）
/// - track 由 DanmakuFloatingView 在 view 层按实际 screenWidth 用 canShoot 分配
struct VideoDanmaku: Identifiable, Hashable, Sendable {
    enum Kind: Int, Hashable, Sendable {
        case scroll = 1   // 滚动（左右飘过）
        case bottom = 4   // 底部固定
        case top = 5      // 顶部固定
        case reverse = 6  // 逆向滚动
    }
    let id: UUID
    let videoTime: Double
    let text: String
    let color: UInt32
    let kind: Kind
    /// 弹幕的自然渲染宽度（CJK 1.0 / ASCII 0.55 字符单位 × 基础字号 40）
    /// 用于 canShoot 碰撞检测；实际渲染时还会按屏幕宽度截断
    let textWidth: CGFloat
}

/// 浮动弹幕渲染（参考 B 站 iOS 客户端实现思路）：
/// 1. TimelineView(.animation) 驱动，60fps 重算位置
/// 2. 视频时间通过 currentTime + (wallNow - lastUpdate) 插值
/// 3. 顶部/底部弹幕不走滚动，按 videoTime 出现在固定行，到期消失
///
/// 活动区约束：调用方需要把本 view 限制在屏幕上 1/4 高度（外部 wrapper frame）。
/// 本 view 内部用 GeometryReader 拿到 activityHeight，再动态算轨道行数。
///
/// ## 性能关键设计
/// - 轨道分配在 `.onAppear` / `.onChange` 中触发, 不在 body 里跑
/// - body 只在 currentVideoTime 4Hz 抖动时被 invalidate, 每次只是重新构造 view 树, 不做计算
/// - 用 ScrollAssigner / FixedAssigner 把分配压成 O(n), 不是 N²
struct DanmakuFloatingView: View {
    let danmakuList: [VideoDanmaku]
    let currentVideoTime: Double
    let lastUpdateWallTime: Date
    let isPlaying: Bool
    let lifetime: Double
    /// 滚动轨道最大数量（实际渲染时按 activityHeight 动态截断）
    let scrollTracks: Int
    /// 顶部弹幕轨道最大数量
    let topTracks: Int
    /// 滚动 + 顶部弹幕活动区高度（外部 wrapper 传入，1/4 屏幕高）
    let activityHeight: CGFloat

    /// 顶部首行 y 坐标（与滚动 track 0 对齐）
    private let firstTrackY: CGFloat = 28
    /// 滚动 track 之间的垂直间距
    private let trackSpacing: CGFloat = 44
    /// 底部弹幕中心 y 距屏幕底边的偏移
    private let bottomMarginFromEdge: CGFloat = 24
    /// 滚动弹幕可用的最大宽度（含内边距），与 DanmakuTrackAssigner.renderWidth 默认一致
    private let scrollHorizontalPadding: CGFloat = 30
    /// 顶部/底部弹幕可用的最大宽度
    private let pinnedHorizontalPadding: CGFloat = 40
    /// 单帧最多渲染多少条滚动弹幕（防止 canShoot 密集模式在极端情况下渲染过多 view）
    private let maxActiveScroll: Int = 250

    // MARK: - 轨道分配状态（不在 body 里更新, 在 onAppear/onChange 触发）
    /// UUID -> track 索引; -1 表示该弹幕因无空位被丢弃
    @State private var trackAssignments: [UUID: Int] = [:]
    /// 上次分配时用的 screenWidth
    @State private var assignedForWidth: CGFloat = 0
    /// 上次分配时用的 danmakuList 指纹（首尾 ID + 数量, 检测新视频/分P）
    @State private var assignedForFingerprint: String = ""
    /// 最近一次 GeometryReader 报告的 width, 用于 danmakuList 变化时也能正确重算
    @State private var lastSeenWidth: CGFloat = 0
    /// 上次分配时用的弹幕密度模式（sparse / dense, off 模式根本不会走 handleWidthChange）
    @State private var assignedForMode: String = ""

    /// 弹幕密度模式（@AppStorage 双向绑定 AppSettings.danmakuDensity, 改完自动 persist）
    @AppStorage("danmaku_density") private var danmakuDensityRaw: String = AppSettings.DanmakuDensity.dense.rawValue

    private var danmakuDensity: AppSettings.DanmakuDensity {
        AppSettings.DanmakuDensity(rawValue: danmakuDensityRaw) ?? .dense
    }

    init(danmakuList: [VideoDanmaku],
         currentVideoTime: Double,
         lastUpdateWallTime: Date,
         isPlaying: Bool,
         lifetime: Double = 6.0,
         scrollTracks: Int = 5,
         topTracks: Int = 5,
         activityHeight: CGFloat = 250) {
        self.danmakuList = danmakuList
        self.currentVideoTime = currentVideoTime
        self.lastUpdateWallTime = lastUpdateWallTime
        self.isPlaying = isPlaying
        self.lifetime = lifetime
        self.scrollTracks = scrollTracks
        self.topTracks = topTracks
        self.activityHeight = activityHeight
    }

    var body: some View {
        GeometryReader { geo in
            let screenHeight = geo.size.height
            let screenWidth = geo.size.width
            let usableHeight = max(0, activityHeight - firstTrackY - bottomMarginFromEdge - 22)
            let trackCount = max(0, min(scrollTracks, Int(usableHeight / trackSpacing) + 1))
            let bottomY = screenHeight - bottomMarginFromEdge

            TimelineView(.animation(minimumInterval: 1.0/60.0)) { context in
                let wallDelta = context.date.timeIntervalSince(lastUpdateWallTime)
                let videoTime = isPlaying ? currentVideoTime + wallDelta : currentVideoTime
                let active = activeDanmaku(at: videoTime)

                ZStack(alignment: .topLeading) {
                    Color.clear
                    if trackCount > 0 {
                        ForEach(active.filter { $0.kind == .top && (trackAssignments[$0.id] ?? -1) >= 0 && (trackAssignments[$0.id] ?? -1) < topTracks }) { d in
                            topPinnedView(d, videoTime: videoTime, screenWidth: screenWidth, track: trackAssignments[d.id] ?? 0)
                        }
                    }
                    ForEach(active.filter { $0.kind == .bottom && (trackAssignments[$0.id] ?? -1) >= 0 }) { d in
                        bottomPinnedView(d, videoTime: videoTime, screenWidth: screenWidth, bottomY: bottomY)
                    }
                    ForEach(active.filter { ($0.kind == .scroll || $0.kind == .reverse) && (trackAssignments[$0.id] ?? -1) >= 0 && (trackAssignments[$0.id] ?? -1) < trackCount }) { d in
                        scrollView(d, videoTime: videoTime, screenWidth: screenWidth, track: trackAssignments[d.id] ?? 0)
                    }
                }
                .frame(width: screenWidth, height: screenHeight)
            }
        }
        .allowsHitTesting(false)
        // 关键: 用 Color.clear 把 GeometryReader 的 size 变化"钩"出来
        // - onAppear: 拿到 view 的真实 width, 触发首次分配
        // - onChange(of: width): rotation / 分屏 → 触发重算
        // - 普通 body 重算（currentTime 4Hz 抖动）不会触发 onChange, 不做计算
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { handleWidthChange(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        handleWidthChange(newWidth)
                    }
            }
        )
        // danmakuList 变化（新视频/分P）→ 用最近一次 width 强制重算
        .onChange(of: danmakuList.count) { _, _ in
            handleWidthChange(lastSeenWidth)
        }
        // 弹幕密度模式变化（用户在播放器切换）→ 强制重算用新算法
        .onChange(of: danmakuDensityRaw) { _, _ in
            handleWidthChange(lastSeenWidth)
        }
        .onAppear {
            // 兜底: 如果 background 里的 GeometryReader 还没上报, 用屏幕宽度
            if lastSeenWidth == 0 {
                handleWidthChange(DanmakuTrackAssigner.currentScreenWidth)
            }
        }
    }

    // MARK: - 轨道分配触发

    /// 宽度变化/列表变化/模式变化时调用
    /// - 缓存命中(width/fingerprint/mode 没变): 立即返回
    /// - 缓存未命中: 跑一次完整分配(O(n) 用 ScrollAssigner/FixedAssigner)
    private func handleWidthChange(_ width: CGFloat) {
        lastSeenWidth = width
        let mode = danmakuDensity
        // off 模式: 已经在外层 if vm.danmakuEnabled 被拦截, 不会进这里, 兜底清空
        if mode == .off {
            trackAssignments = [:]
            assignedForWidth = width
            assignedForFingerprint = ""
            assignedForMode = mode.rawValue
            return
        }
        let fingerprint = "\(danmakuList.count)-\(danmakuList.first?.id.uuidString ?? "nil")-\(danmakuList.last?.id.uuidString ?? "nil")"
        if abs(assignedForWidth - width) < 0.5,
           fingerprint == assignedForFingerprint,
           mode.rawValue == assignedForMode,
           !trackAssignments.isEmpty || danmakuList.isEmpty {
            return
        }
        // 重算（O(n), 用 ScrollAssigner/FixedAssigner 避免 N²）
        let scrollAssigner = ScrollAssigner(
            trackCount: scrollTracks, lifetime: lifetime, viewWidth: width
        )
        let topAssigner = FixedAssigner(
            trackCount: topTracks, lifetime: lifetime
        )
        let bottomAssigner = FixedAssigner(
            trackCount: 1, lifetime: lifetime
        )
        var result: [UUID: Int] = [:]
        let sorted = danmakuList.sorted { $0.videoTime < $1.videoTime }
        let useSparse = (mode == .sparse)
        for d in sorted {
            let t: Int
            switch d.kind {
            case .scroll, .reverse:
                t = useSparse
                    ? scrollAssigner.assignSparse(startTime: d.videoTime)
                    : scrollAssigner.assign(width: d.textWidth, startTime: d.videoTime)
            case .top:
                t = topAssigner.assign(startTime: d.videoTime)
            case .bottom:
                t = bottomAssigner.assign(startTime: d.videoTime)
            }
            result[d.id] = t
        }
        trackAssignments = result
        assignedForWidth = width
        assignedForFingerprint = fingerprint
        assignedForMode = mode.rawValue
    }

    private func activeDanmaku(at videoTime: Double) -> [VideoDanmaku] {
        let active = danmakuList.filter { d in
            let e = videoTime - d.videoTime
            return e >= 0 && e < lifetime
        }
        // 性能保护: 单帧最多渲染 maxActiveScroll 条滚动弹幕
        // canShoot 密集模式在超级热视频里可能让 lifetime 窗口内出现 500+ 条
        // SwiftUI 在 TimelineView 60fps 里创建 500+ Text view 会让主线程每帧花 10+ms,
        // 导致 TimelineView 下一帧 re-eval 被延迟 → 用户看到"弹幕卡住 + 突然跳一截"
        // 截到 maxActiveScroll 后 60fps × 250 = 15k view/sec, 主线程吃得消
        if active.count > maxActiveScroll {
            // 保留最新出现的 maxActiveScroll 条 (按 videoTime 降序取后 maxActiveScroll)
            return Array(active.sorted { $0.videoTime > $1.videoTime }.prefix(maxActiveScroll))
        }
        return active
    }

    @ViewBuilder
    private func scrollView(_ d: VideoDanmaku, videoTime: Double, screenWidth: CGFloat, track: Int) -> some View {
        let elapsed = videoTime - d.videoTime
        let progress = min(max(elapsed / lifetime, 0), 1)
        // 路径长度 = 屏幕宽 + 弹幕实际渲染宽度（与 canShoot 假设一致, 短弹幕慢长弹幕快）
        let renderedWidth = min(d.textWidth, screenWidth - scrollHorizontalPadding)
        let path = screenWidth + renderedWidth
        let x: CGFloat = (d.kind == .reverse)
            ? -renderedWidth / 2 + CGFloat(progress) * path
            : screenWidth + renderedWidth / 2 - CGFloat(progress) * path
        // 滚动轨道 y 与顶部首行 y 一致，间距固定
        let trackY = firstTrackY + CGFloat(track) * trackSpacing
        let alpha = fadeAlpha(elapsed: elapsed)
        // 滚动弹幕的可用宽度是全屏宽 - 30pt 内边距；太长就缩字保证不换行
        let fontSize = fittedFontSize(for: d.text, maxWidth: screenWidth - scrollHorizontalPadding)
        Text(d.text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(colorFromHex(d.color).opacity(alpha))
            .shadow(color: .black.opacity(0.8 * alpha), radius: 2, x: 0, y: 1)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .position(x: x, y: trackY)
    }

    /// 顶部弹幕：和滚动轨道共用同一组 y（视觉重叠是当前设计的取舍）
    /// track 由 handleWidthChange 用 canShoot 算法分配（最多 topTracks 条, 时间窗口不重叠即可同轨）
    @ViewBuilder
    private func topPinnedView(_ d: VideoDanmaku, videoTime: Double, screenWidth: CGFloat, track: Int) -> some View {
        let elapsed = videoTime - d.videoTime
        let y = firstTrackY + CGFloat(track) * trackSpacing
        pinnedTextView(d, elapsed: elapsed, screenWidth: screenWidth, isTop: true, y: y)
    }

    /// 底部弹幕：固定在屏幕最底端一行，最多同时只显示 1 条
    @ViewBuilder
    private func bottomPinnedView(_ d: VideoDanmaku, videoTime: Double, screenWidth: CGFloat, bottomY: CGFloat) -> some View {
        let elapsed = videoTime - d.videoTime
        pinnedTextView(d, elapsed: elapsed, screenWidth: screenWidth, isTop: false, y: bottomY)
    }

    @ViewBuilder
    private func pinnedTextView(_ d: VideoDanmaku, elapsed: Double, screenWidth: CGFloat, isTop: Bool, y: CGFloat) -> some View {
        let alpha = min(1.0, elapsed / 0.3)
        let maxTextWidth = screenWidth - pinnedHorizontalPadding
        // 根据文字长度动态算能塞进 maxTextWidth 的字号
        let fontSize = fittedFontSize(for: d.text, maxWidth: maxTextWidth)
        Text(d.text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(colorFromHex(d.color).opacity(alpha))
            .shadow(color: .black.opacity(0.8 * alpha), radius: 2, x: 0, y: 1)
            .lineLimit(1)              // 绝不换行
            .minimumScaleFactor(0.4)   // 极端长文兜底再缩
            .frame(maxWidth: maxTextWidth)
            .multilineTextAlignment(isTop ? .leading : .center)
            .position(x: screenWidth / 2, y: y)
    }

    /// 按文本长度估算一个能塞进 maxWidth 的字号（中英文按宽度权重不同算）
    private func fittedFontSize(for text: String, maxWidth: CGFloat) -> CGFloat {
        let baseSize: CGFloat = 40
        let units = DanmakuTrackAssigner.widthUnits(of: text)
        let estimatedWidth = units * baseSize
        if estimatedWidth <= maxWidth || units == 0 {
            return baseSize
        }
        return max(baseSize * maxWidth / estimatedWidth, 16)
    }

    private func fadeAlpha(elapsed: Double) -> Double {
        let fadeStart = lifetime * 0.7
        if elapsed < fadeStart { return 1.0 }
        return 1.0 - (elapsed - fadeStart) / (lifetime - fadeStart)
    }

    private func colorFromHex(_ hex: UInt32) -> Color {
        let r = min(max(Double((hex >> 16) & 0xFF) / 255, 0), 1)
        let g = min(max(Double((hex >> 8) & 0xFF) / 255, 0), 1)
        let b = min(max(Double(hex & 0xFF) / 255, 0), 1)
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - 轨道分配算法

/// 弹幕轨道分配器（共享的 canShoot 追击算法 + 字符宽度估算）
///
/// 参考 DanmakuKit: https://github.com/qyz777/DanmakuKit/blob/master/Sources/DanmakuKit/Classes/Core/DanmakuTrack.swift#L114-L145
///
/// 算法核心: 假设所有滚动弹幕的生命周期相同 (lifetime);
/// 速度 = (viewWidth + danmakuWidth) / lifetime (长弹幕走得更快, 视觉速度恒定);
/// 检查新弹幕是否会"追上"轨道上的上一条弹幕, 追上前它已离屏 → 可以同轨。
enum DanmakuTrackAssigner {
    /// 弹幕槽位（参与轨道判定的最小信息）
    struct Slot {
        let track: Int
        let startTime: Double
        let width: CGFloat     // 渲染宽度, 顶部/底部传 0
        let lifetime: Double
    }

    /// 当前激活 windowScene 的屏幕宽度（从 UIWindowScene.screen.bounds 取）
    /// - 来源: UIKit 运行时 API, 不是猜的
    /// - 用途: Live 视图 GeometryReader 还没拿到 viewWidth 时的兜底初值
    static var currentScreenWidth: CGFloat {
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            return windowScene.screen.bounds.width
        }
        return UIScreen.main.bounds.width
    }

    /// 估算弹幕的字符宽度单位 (CJK 1.0, ASCII 0.55)
    static func widthUnits(of text: String) -> CGFloat {
        var units: CGFloat = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x1100...0x115F).contains(v) ||
               (0x2E80...0x303E).contains(v) ||
               (0x3041...0x33FF).contains(v) ||
               (0x3400...0x4DBF).contains(v) ||
               (0x4E00...0x9FFF).contains(v) ||
               (0xA000...0xA4CF).contains(v) ||
               (0xAC00...0xD7A3).contains(v) ||
               (0xF900...0xFAFF).contains(v) ||
               (0xFE30...0xFE4F).contains(v) ||
               (0xFF00...0xFF60).contains(v) ||
               (0xFFE0...0xFFE6).contains(v) {
                units += 1.0
            } else {
                units += 0.55
            }
        }
        return units
    }

    // MARK: - canShoot 核心算法 (参考 DanmakuKit)

    /// 追击问题: 新弹幕能否在 prev 弹幕离屏前追上它
    /// - Returns: true 表示能同轨
    fileprivate static func canShoot(
        nextStart: Double, nextWidth: CGFloat, nextLifetime: Double,
        prevStart: Double, prevWidth: CGFloat, prevLifetime: Double,
        viewWidth: CGFloat
    ) -> Bool {
        let elapsed = nextStart - prevStart
        if elapsed >= prevLifetime { return true }
        if elapsed < 0 { return true }
        let prePath = viewWidth + prevWidth
        let preRight = max(prePath * (1 - elapsed / prevLifetime), 0)
        let distance = viewWidth - preRight - 10
        if distance < 0 { return false }
        let preV = prePath / prevLifetime
        let nextV = (viewWidth + nextWidth) / nextLifetime
        if nextV - preV <= 0 { return true }
        let catchupTime = distance / (nextV - preV)
        let prevRemaining = prevLifetime - elapsed
        return catchupTime >= prevRemaining
    }
}

/// 滚动弹幕轨道分配器（有状态, O(trackCount) per assign）
///
/// 内部维护 `latestPerTrack: [Int: Slot]`, 每次 assign 只查这条字典, 不重扫历史。
/// 对比之前无状态的 `assignScrollTrack`, 每次调用 O(existing) — N 条弹幕是 N²。
final class ScrollAssigner {
    let trackCount: Int
    let lifetime: Double
    let viewWidth: CGFloat
    /// 轨道 → 该轨道上"最新"的那条 slot（速度/位置都基于这条算碰撞）
    private var latestPerTrack: [Int: DanmakuTrackAssigner.Slot] = [:]

    init(trackCount: Int, lifetime: Double, viewWidth: CGFloat,
         existing: [DanmakuTrackAssigner.Slot] = []) {
        self.trackCount = trackCount
        self.lifetime = lifetime
        self.viewWidth = viewWidth
        // O(existing.count) 初始化一次, 后续每次 assign 就是 O(trackCount)
        for s in existing where s.track >= 0 && s.track < trackCount {
            if let cur = latestPerTrack[s.track] {
                if s.startTime > cur.startTime { latestPerTrack[s.track] = s }
            } else {
                latestPerTrack[s.track] = s
            }
        }
    }

    /// 给单条弹幕分配轨道, 0..<trackCount 或 -1（丢弃）
    @discardableResult
    func assign(width: CGFloat, startTime: Double) -> Int {
        for t in 0..<trackCount {
            guard let prev = latestPerTrack[t] else {
                latestPerTrack[t] = .init(track: t, startTime: startTime, width: width, lifetime: lifetime)
                return t
            }
            if DanmakuTrackAssigner.canShoot(
                nextStart: startTime, nextWidth: width, nextLifetime: lifetime,
                prevStart: prev.startTime, prevWidth: prev.width, prevLifetime: prev.lifetime,
                viewWidth: viewWidth
            ) {
                latestPerTrack[t] = .init(track: t, startTime: startTime, width: width, lifetime: lifetime)
                return t
            }
        }
        return -1
    }

    /// 稀疏模式（原版贪心算法）
    /// - 只检查时间窗口不重叠, 不考虑速度追击
    /// - 上一条完全离屏后才放新一条, 画面上同轨同时刻最多一条
    /// - 同 lifetime 下, 画面上同时存在的弹幕数 = trackCount × (新弹幕密度)
    @discardableResult
    func assignSparse(startTime: Double) -> Int {
        for t in 0..<trackCount {
            guard let prev = latestPerTrack[t] else {
                latestPerTrack[t] = .init(track: t, startTime: startTime, width: 0, lifetime: lifetime)
                return t
            }
            // 稀疏: 上一条完全离屏 (startTime >= prevStart + prevLifetime)
            if startTime >= prev.startTime + prev.lifetime {
                latestPerTrack[t] = .init(track: t, startTime: startTime, width: 0, lifetime: lifetime)
                return t
            }
        }
        return -1
    }
}

/// 固定位置弹幕轨道分配器（顶部/底部, O(trackCount) per assign）
final class FixedAssigner {
    let trackCount: Int
    let lifetime: Double
    private var latestPerTrack: [Int: DanmakuTrackAssigner.Slot] = [:]

    init(trackCount: Int, lifetime: Double,
         existing: [DanmakuTrackAssigner.Slot] = []) {
        self.trackCount = trackCount
        self.lifetime = lifetime
        for s in existing where s.track >= 0 && s.track < trackCount {
            if let cur = latestPerTrack[s.track] {
                if s.startTime > cur.startTime { latestPerTrack[s.track] = s }
            } else {
                latestPerTrack[s.track] = s
            }
        }
    }

    /// 给单条弹幕分配轨道, 0..<trackCount 或 -1（丢弃）
    /// - 固定位置: 只检查时间窗口不重叠 (`nextStart >= prevStart + prevLifetime`)
    @discardableResult
    func assign(startTime: Double) -> Int {
        for t in 0..<trackCount {
            guard let prev = latestPerTrack[t] else {
                latestPerTrack[t] = .init(track: t, startTime: startTime, width: 0, lifetime: lifetime)
                return t
            }
            if startTime >= prev.startTime + prev.lifetime {
                latestPerTrack[t] = .init(track: t, startTime: startTime, width: 0, lifetime: lifetime)
                return t
            }
        }
        return -1
    }
}
