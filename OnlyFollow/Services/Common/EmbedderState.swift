import Foundation
import SwiftData
import SwiftUI

/// 「Embedding 建库」状态(全局单例, 给 Settings 展示进度用)
/// - isRunning: 是否有建库任务在跑
/// - processed / total: 进度(本轮)
/// - lastRunAt / lastRunCount: 上次完成时间 + 写入条数
@MainActor
final class EmbedderState: ObservableObject {
    static let shared = EmbedderState()

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var processed: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastRunCount: Int = 0
    @Published private(set) var lastError: String?

    /// 当前在 VideoRecord 里但还没在 VideoEmbedding 里的数量(给 Settings 展示"待补")
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var embeddedCount: Int = 0

    private init() {}

    /// 由 Settings 里的「重新构建」按钮触发
    /// - 同一时刻只跑一次(去重)
    /// - 不阻塞 UI
    func startRebuild() {
        guard !isRunning else {
            AppLogger.info("EmbedderState: 已有任务在跑, 忽略新触发")
            return
        }
        isRunning = true
        processed = 0
        total = 0
        lastError = nil
        Task.detached(priority: .userInitiated) {
            let ctx = ModelContext(OnlyFollowApp.sharedContainer)
            do {
                // 走带 onProgress 的重载, 让 UI 能看到进度
                let n = try await VideoEmbedder.runOnce(context: ctx) { [weak self] p, t in
                    Task { @MainActor in
                        self?.processed = p
                        self?.total = t
                    }
                }
                await MainActor.run {
                    self.isRunning = false
                    self.lastRunAt = Date()
                    self.lastRunCount = n
                    AppLogger.info("EmbedderState: 重建完成, 共写入 \\(n) 条")
                    self.refreshCounts(context: ctx)
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.lastError = error.localizedDescription
                    AppLogger.error("EmbedderState: 重建失败: \\(error.localizedDescription)")
                }
            }
        }
    }

    /// 启动时让后台建库(无 UI 反馈, 走 Settings "上次运行"那一栏)
    func kickoffBackground() {
        RecommendationService.kickoffBackgroundEmbedIfNeeded()
    }

    /// 刷新 pendingCount / embeddedCount (给 Settings 展示"X / Y"用)
    func refreshCounts(context: ModelContext) {
        let videos = (try? context.fetch(FetchDescriptor<VideoRecord>())) ?? []
        let embeddings = (try? context.fetch(FetchDescriptor<VideoEmbedding>())) ?? []
        let embByAid: [Int: VideoEmbedding] = Dictionary(uniqueKeysWithValues: embeddings.map { ($0.aid, $0) })
        let pending = videos.filter { r in
            guard let e = embByAid[r.aid] else { return true }
            return e.modelName != AppSettings.embeddingModel || e.titleSnapshot != r.title
        }
        embeddedCount = videos.count - pending.count
        pendingCount = pending.count
    }
}
