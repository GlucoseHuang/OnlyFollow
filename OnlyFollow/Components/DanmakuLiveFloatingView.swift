import SwiftUI

/// 直播飘屏（抖音直播用）
///
/// ## 核心架构（解决流式弹幕卡顿问题）
///
/// 旧实现的卡顿原因：每条新消息到来时，`messages: [DanmakuMessage]` prop 变化
/// 会导致整个 view tree 重建（GeometryReader、TimelineView、ForEach 全部销毁重建）。
/// TimelineView 重新计时后，老弹幕的 `elapsed` 突然跳到「重建耗时后的值」，
/// 视觉上表现为弹幕位置突变 + 整体卡顿。
///
/// 本实现的修复（与 BarrageRenderer 等成熟 iOS 弹幕库做法一致）：
/// 1. 内部用 `@State private var activeMsgs: [LiveDanmaku]` 维护渲染状态
///    - track 在新消息到来时一次性分配，**永不变** → 弹幕不跳轨道
///    - activeMsgs 独立于外部 messages 数组，**不随外部数据变化重建 view tree**
/// 2. `onChange(of: messages.last?.id)` 增量同步新消息到 activeMsgs
/// 3. `.task` 1Hz 兜底清理过期弹幕
/// 4. TimelineView 60fps 只对 activeMsgs 做 filter + render，与外部 messages 解耦
///
/// ## 切后台 / 切回前台
/// - **不**清空 activeMsgs（保留切走时的弹幕状态）
/// - 切回前台时把每个 activeMsg 的 appearedAt 加上「后台时长」，
///   让 elapsed = now - appearedAt 等于「切走时的 elapsed」→ 弹幕从切走时的位置继续飘
/// - 后台期间新推送的消息在 syncNewMessages 里用 `appearedAt = now` 处理，防止从屏幕中间闪现
///
/// ## 视觉参数（与 B 站视频 DanmakuFloatingView 完全一致）
/// - 最多 5 条滚动轨道（按 activityHeight 动态限制）
/// - lifetime 6s（最后 30% 渐隐）
/// - 基础字号 40pt（CJK 1.0 / ASCII 0.55 宽度单位自动收缩，最小 16pt）
/// - system semibold 字体
/// - 黑色阴影 0.8 alpha radius 2
/// - 轨道间距 44pt，首行 y = 28
struct DanmakuLiveFloatingView: View {
    let messages: [DanmakuMessage]
    /// 滚动活动区高度（外部 wrapper 传入，视频侧取 1/4 屏高）
    let activityHeight: CGFloat
    /// 单条弹幕存活时间（秒）
    let lifetime: Double
    /// 滚动轨道最大数量
    let scrollTracks: Int

    private let firstTrackY: CGFloat = 28
    private let trackSpacing: CGFloat = 44
    /// 滚动弹幕可用的最大宽度（含内边距），与 DanmakuTrackAssigner.renderWidth 默认一致
    private let scrollHorizontalPadding: CGFloat = 30
    /// 单帧最多保留多少条 activeMsgs（保护渲染性能）
    private let maxActive: Int = 250

    /// 弹幕密度模式（@AppStorage 绑定 AppSettings.danmakuDensity, 用户切密度自动重新分配）
    @AppStorage("danmaku_density") private var danmakuDensityRaw: String = AppSettings.DanmakuDensity.dense.rawValue

    private var danmakuDensity: AppSettings.DanmakuDensity {
        AppSettings.DanmakuDensity(rawValue: danmakuDensityRaw) ?? .dense
    }

    /// view 内部维护的渲染状态。track 一次性分配，永不变。
    @State private var activeMsgs: [LiveDanmaku] = []
    /// 切到后台的时刻；切回前台时用来算后台时长并偏移 appearedAt
    @State private var lastBackgroundAt: Date?
    /// 当前视图宽度（来自 GeometryReader, 用于 canShoot 碰撞检测）
    /// 初值取自当前 windowScene 的屏幕宽度（来源: UIWindowScene.screen.bounds）,
    /// 拿到 view 后立即被 GeometryReader 覆盖为精确的 view 宽度
    @State private var viewWidth: CGFloat = DanmakuTrackAssigner.currentScreenWidth
    @Environment(\.scenePhase) private var scenePhase

    init(messages: [DanmakuMessage],
         lifetime: Double = 6.0,
         scrollTracks: Int = 5,
         activityHeight: CGFloat = 250) {
        self.messages = messages
        self.lifetime = lifetime
        self.scrollTracks = scrollTracks
        self.activityHeight = activityHeight
    }

    private var trackCount: Int {
        let usableHeight = max(0, activityHeight - firstTrackY - 22)
        return max(1, min(scrollTracks, Int(usableHeight / trackSpacing) + 1))
    }

    var body: some View {
        GeometryReader { geo in
            let screenWidth = geo.size.width

            TimelineView(.animation(minimumInterval: 1.0/60.0)) { context in
                let now = context.date
                let cutoff = now.addingTimeInterval(-lifetime)
                let visible = activeMsgs.filter { $0.appearedAt >= cutoff }

                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(visible) { msg in
                        scrollView(msg, screenWidth: screenWidth, now: now)
                    }
                }
                .frame(width: screenWidth, height: geo.size.height)
            }
            // GeometryReader 拿到真实屏幕宽度后, 立即更新 viewWidth 供 canShoot 使用
            .onAppear {
                if viewWidth != screenWidth { viewWidth = screenWidth }
            }
            .onChange(of: screenWidth) { _, newWidth in
                viewWidth = newWidth
            }
        }
        .allowsHitTesting(false)
        .onAppear { syncNewMessages() }
        .onChange(of: messages.last?.id) {
            syncNewMessages()
        }
        // 弹幕密度模式变化 → 清空 activeMsgs 重新分配
        // (现有 activeMsgs 是按旧模式算的 track, 切模式后 track 数量/算法都变了, 旧 track 无意义)
        .onChange(of: danmakuDensityRaw) { _, _ in
            activeMsgs.removeAll()
            syncNewMessages()
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
        .task(id: scenePhase) {
            // 只在前台时跑 1Hz 清理，节省后台资源
            // 注意：这里依赖 scenePhase 环境值判断，但 .task 是异步启动的，scenePhase 此时通常已稳定
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let cutoff = Date().addingTimeInterval(-lifetime)
                if activeMsgs.contains(where: { $0.appearedAt < cutoff }) {
                    activeMsgs.removeAll { $0.appearedAt < cutoff }
                }
            }
        }
    }

    /// 切到后台 / 切回前台的状态处理
    /// - background：记录切走时刻
    /// - active：把每个 activeMsg 的 appearedAt 加上「后台时长」，
    ///   让 elapsed 保持切走时的值 → 弹幕从切走时的位置继续飘（不跳变、不消失）
    ///   顺便同步后台期间新推送的消息
    private func handleScenePhase(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            lastBackgroundAt = Date()
        case .active:
            if let bgAt = lastBackgroundAt {
                let pauseDuration = Date().timeIntervalSince(bgAt)
                if pauseDuration > 0 {
                    // 偏移所有活跃弹幕的 appearedAt：让 elapsed = now - appearedAt
                    // 等于"切走时的 elapsed"（即暂停了内部时钟）
                    activeMsgs = activeMsgs.map { msg in
                        LiveDanmaku(
                            id: msg.id,
                            text: msg.text,
                            color: msg.color,
                            appearedAt: msg.appearedAt.addingTimeInterval(pauseDuration),
                            track: msg.track,
                            width: msg.width
                        )
                    }
                    // 清理可能因 paused 而过期的消息
                    let now = Date()
                    activeMsgs.removeAll { now.timeIntervalSince($0.appearedAt) > lifetime }
                }
                lastBackgroundAt = nil
            }
            // 同步后台期间新推送的消息
            syncNewMessages()
        case .inactive:
            // 短暂失去焦点（控制中心、通知中心等），UI 还在，不处理
            break
        @unknown default:
            break
        }
    }

    /// 增量同步：把 messages 中 activeMsgs 还没记录的新消息 push 进来，分配 track
    /// - **不**在内部检查 scenePhase（SwiftUI 的 @Environment(\.scenePhase) 更新是异步的，
    ///   在 onAppear 闭包里读可能是 .inactive，会误跳过导致弹幕完全不显示）。
    ///   改由 handleScenePhase(.background) 在切到后台时清空 activeMsgs 来控制。
    /// - 大延迟消息（now - msg.timestamp > 0.5s，可能是网络延迟或后台累积）用 `appearedAt = now`
    ///   防止从屏幕中间闪现
    /// - 正常消息用 `appearedAt = msg.timestamp`（实时感）
    private func syncNewMessages() {
        let existingIDs = Set(activeMsgs.map(\.id))
        let newMsgs = messages.filter { !existingIDs.contains($0.id) }
        let now = Date()
        let tc = trackCount
        let mode = danmakuDensity
        let useSparse = (mode == .sparse)

        // off 模式: 清空 activeMsgs, 不显示任何弹幕
        if mode == .off {
            activeMsgs.removeAll()
            return
        }

        // 构造已有槽位（用 activeMsgs 初始化 ScrollAssigner, O(activeMsgs.count) 一次）
        // - 后续每个新弹幕的 assign 是 O(trackCount), 不是 O(existing)
        // - 同批到达的弹幕由 ScrollAssigner 内部 latestPerTrack 增量更新, 也会互检
        let existingSlots = activeMsgs
            .filter { $0.track >= 0 && $0.track < tc }
            .map { msg in
                DanmakuTrackAssigner.Slot(
                    track: msg.track,
                    startTime: msg.appearedAt.timeIntervalSince1970,
                    width: msg.width,
                    lifetime: lifetime
                )
            }
        let assigner = ScrollAssigner(
            trackCount: tc, lifetime: lifetime, viewWidth: viewWidth,
            existing: existingSlots
        )

        for msg in newMsgs.sorted(by: { $0.timestamp < $1.timestamp }) {
            // 跳过已过 lifetime 的消息
            if now.timeIntervalSince(msg.timestamp) >= lifetime {
                continue
            }
            // 决定 appearedAt：
            //   - delta < 0.5s（正常消息）：用 msg.timestamp 保持实时感
            //   - delta >= 0.5s（大延迟，可能是网络延迟）：用 now 防止从屏幕中间闪现
            let delta = now.timeIntervalSince(msg.timestamp)
            let appearedAt = delta < 0.5 ? msg.timestamp : now
            // 弹幕渲染宽度（自然宽度, 实际渲染时由 scrollView 按屏幕宽度 cap）
            let width = DanmakuTrackAssigner.widthUnits(of: msg.content) * 40
            let startTime = appearedAt.timeIntervalSince1970
            let track: Int
            if useSparse {
                track = assigner.assignSparse(startTime: startTime)
            } else {
                track = assigner.assign(width: width, startTime: startTime)
            }
            if track >= 0 {
                activeMsgs.append(LiveDanmaku(
                    id: msg.id,
                    text: msg.content,
                    color: msg.color,
                    appearedAt: appearedAt,
                    track: track,
                    width: width
                ))
            }
        }
        // 顺便清理过期
        activeMsgs.removeAll { now.timeIntervalSince($0.appearedAt) > lifetime }
        // 性能保护: 直播在峰值可能瞬时涌入大量弹幕
        // 把超出 maxActive 的最老的截掉, 避免 TimelineView 60fps × 500+ view 把主线程拖死
        if activeMsgs.count > maxActive {
            activeMsgs = Array(activeMsgs.sorted { $0.appearedAt > $1.appearedAt }.prefix(maxActive))
        }
    }

    @ViewBuilder
    private func scrollView(_ msg: LiveDanmaku, screenWidth: CGFloat, now: Date) -> some View {
        let elapsed = now.timeIntervalSince(msg.appearedAt)
        let progress = min(max(elapsed / lifetime, 0), 1)
        // 路径长度 = 屏幕宽 + 弹幕实际渲染宽度（与 canShoot 假设一致, 短弹幕慢长弹幕快）
        let renderedWidth = min(msg.width, screenWidth - scrollHorizontalPadding)
        let path = screenWidth + renderedWidth
        let x = screenWidth + renderedWidth / 2 - CGFloat(progress) * path
        let trackY = firstTrackY + CGFloat(msg.track) * trackSpacing
        let alpha = fadeAlpha(elapsed: elapsed)
        let fontSize = fittedFontSize(for: msg.text, maxWidth: screenWidth - scrollHorizontalPadding)
        Text(msg.text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(colorFromHex(msg.color).opacity(alpha))
            .shadow(color: .black.opacity(0.8 * alpha), radius: 2, x: 0, y: 1)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .position(x: x, y: trackY)
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

/// 渲染内部状态（track 一次性分配，永不变）
private struct LiveDanmaku: Identifiable, Equatable {
    let id: UUID
    let text: String
    let color: UInt32
    let appearedAt: Date
    let track: Int
    /// 弹幕自然渲染宽度（CJK 1.0 / ASCII 0.55 字符单位 × 基础字号 40）
    let width: CGFloat
}
