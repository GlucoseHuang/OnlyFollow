import Foundation
import SwiftUI

/// 视频弹幕的内部表示
/// - videoTime: 出现时刻（视频秒数）
/// - kind: 滚动 / 顶部 / 底部（参考 B 站 type 字段）
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
    /// 滚动弹幕的轨道行号（0~scrollTracks-1）；-1 表示该弹幕因轨道冲突被丢弃
    var track: Int = 0
}

/// 浮动弹幕渲染（参考 B 站 iOS 客户端实现思路）：
/// 1. TimelineView(.animation) 驱动，60fps 重算位置
/// 2. 视频时间通过 currentTime + (wallNow - lastUpdate) 插值
/// 3. 顶部/底部弹幕不走滚动，按 videoTime 出现在固定行，到期消失
///
/// 活动区约束：调用方需要把本 view 限制在屏幕上 1/4 高度（外部 wrapper frame）。
/// 本 view 内部用 GeometryReader 拿到 activityHeight，再动态算轨道行数。
struct DanmakuFloatingView: View {
    let danmakuList: [VideoDanmaku]
    let currentVideoTime: Double
    let lastUpdateWallTime: Date
    let isPlaying: Bool
    let lifetime: Double
    /// view model 阶段分配的最大可能轨道数（=scrollTracks of assignTracks）
    let scrollTracks: Int
    /// 滚动 + 顶部弹幕活动区高度（外部 wrapper 传入，1/4 屏幕高）
    let activityHeight: CGFloat

    /// 顶部首行 y 坐标（与滚动 track 0 对齐）
    private let firstTrackY: CGFloat = 28
    /// 滚动 track 之间的垂直间距
    private let trackSpacing: CGFloat = 44
    /// 底部弹幕中心 y 距屏幕底边的偏移
    private let bottomMarginFromEdge: CGFloat = 24
    /// 顶部弹幕最大同时显示条数（超出直接丢弃，不挤到其他行）
    private let maxTopConcurrent: Int = 2

    init(danmakuList: [VideoDanmaku],
         currentVideoTime: Double,
         lastUpdateWallTime: Date,
         isPlaying: Bool,
         lifetime: Double = 6.0,
         scrollTracks: Int = 5,
         activityHeight: CGFloat = 250) {
        self.danmakuList = danmakuList
        self.currentVideoTime = currentVideoTime
        self.lastUpdateWallTime = lastUpdateWallTime
        self.isPlaying = isPlaying
        self.lifetime = lifetime
        self.scrollTracks = scrollTracks
        self.activityHeight = activityHeight
    }

    var body: some View {
        GeometryReader { geo in
            let screenHeight = geo.size.height
            let screenWidth = geo.size.width
            // 动态轨道行数：
            //   - 顶部留 firstTrackY（28pt）给首行
            //   - 底部留 bottomMarginFromEdge + 22pt（文字半高）给 bottom 弹幕
            //   - 中间剩余空间按 trackSpacing 切，能放几行放几行
            //   - 上限是 view model 分配的 scrollTracks
            let usableHeight = max(0, activityHeight - firstTrackY - bottomMarginFromEdge - 22)
            let trackCount = max(0, min(scrollTracks, Int(usableHeight / trackSpacing) + 1))
            // 底部弹幕定位在屏幕最底端（不是 1/4 活动区的底端）
            let bottomY = screenHeight - bottomMarginFromEdge

            TimelineView(.animation(minimumInterval: 1.0/60.0)) { context in
                let wallDelta = context.date.timeIntervalSince(lastUpdateWallTime)
                let videoTime = isPlaying ? currentVideoTime + wallDelta : currentVideoTime
                let active = activeDanmaku(at: videoTime)

                ZStack(alignment: .topLeading) {
                    Color.clear
                    if trackCount > 0 {
                        ForEach(active.filter { $0.kind == .top }) { d in
                            topPinnedView(d, videoTime: videoTime, screenWidth: screenWidth, trackCount: trackCount)
                        }
                    }
                    ForEach(active.filter { $0.kind == .bottom }) { d in
                        bottomPinnedView(d, videoTime: videoTime, screenWidth: screenWidth, bottomY: bottomY)
                    }
                    ForEach(active.filter { ($0.kind == .scroll || $0.kind == .reverse) && $0.track >= 0 && $0.track < trackCount }) { d in
                        scrollView(d, videoTime: videoTime, screenWidth: screenWidth)
                    }
                }
                .frame(width: screenWidth, height: screenHeight)
            }
        }
        .allowsHitTesting(false)
    }

    private func activeDanmaku(at videoTime: Double) -> [VideoDanmaku] {
        danmakuList.filter { d in
            let e = videoTime - d.videoTime
            return e >= 0 && e < lifetime
        }
    }

    @ViewBuilder
    private func scrollView(_ d: VideoDanmaku, videoTime: Double, screenWidth: CGFloat) -> some View {
        let elapsed = videoTime - d.videoTime
        let progress = min(max(elapsed / lifetime, 0), 1)
        let x: CGFloat = (d.kind == .reverse)
            ? -300 + CGFloat(progress) * (screenWidth + 300)
            : screenWidth + 200 - CGFloat(progress) * (screenWidth + 400)
        // 滚动轨道 y 与顶部首行 y 一致，间距固定
        let trackY = firstTrackY + CGFloat(d.track) * trackSpacing
        let alpha = fadeAlpha(elapsed: elapsed)
        // 滚动弹幕的可用宽度是全屏宽 - 30pt 内边距；太长就缩字保证不换行
        let fontSize = fittedFontSize(for: d.text, maxWidth: screenWidth - 30)
        Text(d.text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(colorFromHex(d.color).opacity(alpha))
            .shadow(color: .black.opacity(0.8 * alpha), radius: 2, x: 0, y: 1)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .position(x: x, y: trackY)
    }

    /// 顶部弹幕：和滚动轨道共用同一组 y，最多同时显示 maxTopConcurrent 条；超出直接丢弃
    @ViewBuilder
    private func topPinnedView(_ d: VideoDanmaku, videoTime: Double, screenWidth: CGFloat, trackCount: Int) -> some View {
        let elapsed = videoTime - d.videoTime
        let sameTypeBefore = concurrentPinnedCount(before: d, kind: .top)
        if sameTypeBefore >= maxTopConcurrent {
            // 超出上限直接丢弃，不下移到下一行
            EmptyView()
        } else {
            let row = sameTypeBefore
            let y = firstTrackY + CGFloat(row) * trackSpacing
            pinnedTextView(d, elapsed: elapsed, screenWidth: screenWidth, isTop: true, y: y)
        }
    }

    /// 底部弹幕：固定在屏幕最底端一行，最多同时只显示 1 条
    @ViewBuilder
    private func bottomPinnedView(_ d: VideoDanmaku, videoTime: Double, screenWidth: CGFloat, bottomY: CGFloat) -> some View {
        let sameTypeBefore = concurrentPinnedCount(before: d, kind: .bottom)
        if sameTypeBefore >= 1 {
            EmptyView()
        } else {
            let elapsed = videoTime - d.videoTime
            pinnedTextView(d, elapsed: elapsed, screenWidth: screenWidth, isTop: false, y: bottomY)
        }
    }

    /// 统计与 `d` 同类型（top/bottom）且在 [d.videoTime - lifetime, d.videoTime) 区间内的弹幕数量，
    /// 用于决定堆叠行号。lifetime 之内出现的更早弹幕会与 `d` 在屏幕上同时存在，所以需要错开行。
    private func concurrentPinnedCount(before d: VideoDanmaku, kind: VideoDanmaku.Kind) -> Int {
        danmakuList.reduce(0) { acc, other in
            guard other.kind == kind,
                  other.videoTime < d.videoTime,
                  abs(other.videoTime - d.videoTime) < lifetime else { return acc }
            return acc + 1
        }
    }

    @ViewBuilder
    private func pinnedTextView(_ d: VideoDanmaku, elapsed: Double, screenWidth: CGFloat, isTop: Bool, y: CGFloat) -> some View {
        let alpha = min(1.0, elapsed / 0.3)
        let maxTextWidth = screenWidth - 40
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
        // CJK 字符按 1.0 个字符宽度算，ASCII 字符按 0.55
        var totalWidthUnits: CGFloat = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // CJK 统一汉字 + 全角标点 + 日文 + 韩文
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
                totalWidthUnits += 1.0
            } else {
                totalWidthUnits += 0.55
            }
        }
        let estimatedWidth = totalWidthUnits * baseSize
        if estimatedWidth <= maxWidth || totalWidthUnits == 0 {
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

/// 弹幕轨道分配器（ViewModel 解析 XML 时调用）
enum DanmakuTrackAssigner {
    /// 给一段已按 videoTime 排序的弹幕分配 track
    /// 策略：对每条滚动弹幕，找一个 [videoTime, videoTime + lifetime] 内空闲的轨道
    /// 全占就丢（返回 track = -1），由 View 端跳过
    static func assignTracks(to danmakuList: [VideoDanmaku], lifetime: Double, trackCount: Int) -> [UUID: Int] {
        var trackEndTime: [Int: Double] = [:]
        var assigned: [UUID: Int] = [:]
        for d in danmakuList {
            switch d.kind {
            case .top, .bottom:
                assigned[d.id] = -1  // 置顶/置底不需要 track
            case .scroll, .reverse:
                var found = -1
                for t in 0..<trackCount {
                    let endTime = trackEndTime[t] ?? -.infinity
                    if d.videoTime >= endTime {
                        found = t
                        trackEndTime[t] = d.videoTime + lifetime
                        break
                    }
                }
                assigned[d.id] = found
            }
        }
        return assigned
    }
}
